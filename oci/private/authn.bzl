"repository rule that locates the .docker/config.json or containers/auth.json file."

load("@aspect_bazel_lib//lib:base64.bzl", "base64")
load("@aspect_bazel_lib//lib:repo_utils.bzl", "repo_utils")
load(":util.bzl", "util")

# Unfortunately bazel downloader doesn't let us sniff the WWW-Authenticate header, therefore we need to
# keep a map of known registries that require us to acquire a temporary token for authentication.
_WWW_AUTH = {
    "index.docker.io": {
        "realm": "auth.docker.io/token",
        "scope": "repository:{repository}:pull",
        "service": "registry.docker.io",
    },
    "public.ecr.aws": {
        "realm": "{registry}/token",
        "scope": "repository:{repository}:pull",
        "service": "{registry}",
    },
    "ghcr.io": {
        "realm": "{registry}/token",
        "scope": "repository:{repository}:pull",
        "service": "{registry}/token",
    },
    "cgr.dev": {
        "realm": "{registry}/token",
        "scope": "repository:{repository}:pull",
        "service": "{registry}",
    },
    ".azurecr.io": {
        "realm": "{registry}/oauth2/token",
        "scope": "repository:{repository}:pull",
        "service": "{registry}",
    },
    "registry.gitlab.com": {
        "realm": "gitlab.com/jwt/auth",
        "scope": "repository:{repository}:pull",
        "service": "container_registry",
    },
    ".app.snowflake.com": {
        "realm": "{registry}/v2/token",
        "scope": "repository:{repository}:pull",
        "service": "{registry}",
    },
    "docker.elastic.co": {
        "realm": "docker-auth.elastic.co/auth",
        "scope": "repository:{repository}:pull",
        "service": "token-service",
    },
    "quay.io": {
        "realm": "{registry}/v2/auth",
        "scope": "repository:{repository}:pull",
        "service": "{registry}",
    },
    "nvcr.io": {
        "realm": "{registry}/proxy_auth",
        "scope": "repository:{repository}:pull",
        "service": "{registry}",
    },
}

def _strip_host(url):
    # TODO: a principled way of doing this
    return url.replace("http://", "").replace("https://", "").replace("/v1/", "")

# Path of the auth file is determined by the order described here;
# https://github.com/google/go-containerregistry/tree/main/pkg/authn#tldr-for-consumers-of-this-package
def _get_auth_file_path(rctx):
    HOME = repo_utils.get_env_var(rctx, "HOME", "ERR_NO_HOME_SET")

    # this is the standard path where registry credentials are stored
    # https://docs.docker.com/engine/reference/commandline/cli/#configuration-files
    DOCKER_CONFIG = "{}/.docker".format(HOME)

    # set DOCKER_CONFIG to $DOCKER_CONFIG env if present
    if "DOCKER_CONFIG" in rctx.os.environ:
        DOCKER_CONFIG = rctx.os.environ["DOCKER_CONFIG"]

    config_path = "{}/config.json".format(DOCKER_CONFIG)

    if util.file_exists(rctx, config_path):
        return config_path

    # https://docs.podman.io/en/latest/markdown/podman-login.1.html#authfile-path
    XDG_RUNTIME_DIR = "{}/.config".format(HOME)

    # set XDG_RUNTIME_DIR to $XDG_RUNTIME_DIR env if present
    if "XDG_RUNTIME_DIR" in rctx.os.environ:
        XDG_RUNTIME_DIR = rctx.os.environ["XDG_RUNTIME_DIR"]

    config_path = "{}/containers/auth.json".format(XDG_RUNTIME_DIR)

    # podman support overriding the standard path for the auth file via this special environment variable.
    # https://docs.podman.io/en/latest/markdown/podman-login.1.html#authfile-path
    if "REGISTRY_AUTH_FILE" in rctx.os.environ:
        config_path = rctx.os.environ["REGISTRY_AUTH_FILE"]

    if util.file_exists(rctx, config_path):
        return config_path

    return None

def _fetch_auth_via_creds_helper(rctx, raw_host, helper_name, allow_fail = False):
    if rctx.os.name.startswith("windows"):
        executable = "{}.bat".format(helper_name)
        rctx.file(
            executable,
            content = """\
@echo off
echo %1 | docker-credential-{} get """.format(helper_name),
        )
    else:
        executable = "{}.sh".format(helper_name)
        rctx.file(
            executable,
            content = """\
#!/usr/bin/env bash
exec "docker-credential-{}" get <<< "$1" """.format(helper_name),
        )
    result = rctx.execute([rctx.path(executable), raw_host])
    if result.return_code:
        if not allow_fail:
            fail("credential helper failed: \nSTDOUT:\n{}\nSTDERR:\n{}".format(result.stdout, result.stderr))
        else:
            return {}

    response = json.decode(result.stdout)

    # If the username and secret are empty, the user does not have a login.
    # Returning {} avoids sending invalid Basic auth headers that result in 401's
    if response["Username"] == "" and response["Secret"] == "":
        return {}

    return {
        "type": "basic",
        "login": response["Username"],
        "password": response["Secret"],
    }

OAUTH_2_SCRIPT_POWERSHELL = """\
param (
    [string]$url,
    [string]$service,
    [string]$scope,
    [string]$refresh_token
)

try {
    $response = Invoke-RestMethod -Uri $url -Method Post -Body @{
        grant_type = "refresh_token"
        service = $service
        scope = $scope
        refresh_token = $refresh_token
    } -ErrorAction Stop

    $jsonResponse = $response | ConvertTo-Json
    echo $jsonResponse
} catch {
    $ErrorMessage = $_.Exception.Message
    Write-Error "oauth2 failed: PowerShell request failed with error: $ErrorMessage"
    exit 1
}
"""

OAUTH_2_SCRIPT_CURL = """\
url=$1
service=$2
scope=$3
refresh_token=$4

response=$(curl --silent --show-error --fail --request POST --data "grant_type=refresh_token&service=$service&scope=$scope&refresh_token=$refresh_token" $url)

if [ $? -ne 0 ]; then
    exit 1
fi

echo "$response"
"""

OAUTH_2_SCRIPT_WGET = """\
url=$1
service=$2
scope=$3
refresh_token=$4

response=$(wget --quiet --output-document=- --post-data "grant_type=refresh_token&service=$service&scope=$scope&refresh_token=$refresh_token" $url)

if [ $? -ne 0 ]; then
    exit 1
fi

echo "$response"
"""

def _oauth2(rctx, realm, scope, service, secret):
    if rctx.os.name.startswith("windows") and rctx.which("powershell"):
        executable = "oauth2.ps1"
        rctx.file(executable, content = OAUTH_2_SCRIPT_POWERSHELL)
        result = rctx.execute(["powershell", "-File", rctx.path(executable), realm, service, scope, secret])
    elif rctx.which("curl"):
        executable = "oauth2.sh"
        rctx.file(executable, content = OAUTH_2_SCRIPT_CURL)
        result = rctx.execute(["bash", rctx.path(executable), realm, service, scope, secret])
    elif rctx.which("wget"):
        executable = "oauth2.sh"
        rctx.file(executable, content = OAUTH_2_SCRIPT_WGET)
        result = rctx.execute(["bash", rctx.path(executable), realm, service, scope, secret])
    else:
        fail("oauth2 failed, could not find either of: curl, wget, powershell")

    if result.return_code:
        fail("oauth2 failed:\nSTDOUT:\n{}\nSTDERR:\n{}".format(result.stdout, result.stderr))
    return result.stdout

def _get_auth(rctx, state, registry):
    # if we have a cached auth for this registry then just return it.
    # this will prevent repetitive calls to external cred helper binaries.
    if registry in state["auth"]:
        return state["auth"][registry]

    pattern = {}
    config = state["config"]

    # first look into per registry credHelpers if it exists
    if "credHelpers" in config:
        for host_raw in config["credHelpers"]:
            host = _strip_host(host_raw)
            if host == registry:
                helper_val = config["credHelpers"][host_raw]
                pattern = _fetch_auth_via_creds_helper(rctx, host_raw, helper_val)

    # if no match for per registry credential helper for the host then look into auths dictionary
    if "auths" in config and len(pattern.keys()) == 0:
        for host_raw in config["auths"]:
            host = _strip_host(host_raw)
            if host == registry:
                auth_val = config["auths"][host_raw]

                if len(auth_val.keys()) == 0:
                    # zero keys indicates that credentials are stored in credsStore helper.
                    pattern = _fetch_auth_via_creds_helper(rctx, host_raw, config["credsStore"])

                elif "auth" in auth_val:
                    # base64 encoded plaintext username and password
                    raw_auth = auth_val["auth"]
                    login, sep, password = base64.decode(raw_auth).partition(":")
                    if not sep:
                        fail("auth string must be in form username:password")
                    if not password and "identitytoken" in auth_val:
                        password = auth_val["identitytoken"]
                    pattern = {
                        "type": "basic",
                        "login": login,
                        "password": password,
                    }

                elif "username" in auth_val and "password" in auth_val:
                    # plain text username and password
                    pattern = {
                        "type": "basic",
                        "login": auth_val["username"],
                        "password": auth_val["password"],
                    }

    # look for generic credentials-store all lookups for host-specific auth fails
    if "credsStore" in config and len(pattern.keys()) == 0:
        pattern = _fetch_auth_via_creds_helper(rctx, registry, config["credsStore"], allow_fail = True)

    # cache the result so that we don't do this again unnecessarily.
    state["auth"][registry] = pattern

    return pattern

IDENTITY_TOKEN_WARNING = """\
OAuth2 support for oci_pull is highly experimental and is not enabled by default.

We may change or abandon it without a notice. Use it at your own peril!

To enable this feature, add `common --repo_env=OCI_ENABLE_OAUTH2_SUPPORT=1` to the `.bazelrc` file.
"""

def _get_token(rctx, state, registry, repository):
    allow_fail = rctx.os.environ.get("OCI_GET_TOKEN_ALLOW_FAIL") != None
    pattern = _get_auth(rctx, state, registry)

    for registry_pattern in _WWW_AUTH.keys():
        if (registry == registry_pattern) or registry.endswith(registry_pattern):
            www_authenticate = _WWW_AUTH[registry_pattern]
            url = "https://{realm}?scope={scope}&service={service}".format(
                realm = www_authenticate["realm"].format(registry = registry),
                service = www_authenticate["service"].format(registry = registry),
                scope = www_authenticate["scope"].format(repository = repository),
            )

            # if a token for this repository and registry is acquired, use that instead.
            if url in state["token"]:
                return state["token"][url]

            auth = None
            if pattern.get("login", None) == "<token>":
                if not rctx.os.environ.get("OCI_ENABLE_OAUTH2_SUPPORT"):
                    if allow_fail:
                        return {}
                    fail(IDENTITY_TOKEN_WARNING)

                response = _oauth2(
                    rctx = rctx,
                    realm = "https://" + www_authenticate["realm"].format(registry = registry),
                    scope = www_authenticate["scope"].format(repository = repository),
                    service = www_authenticate["service"].format(registry = registry),
                    secret = pattern["password"],
                )

                rctx.file(
                    "www-authenticate.json",
                    content = response,
                    executable = False,
                )
            else:
                result = rctx.download(
                    url = [url],
                    output = "www-authenticate.json",
                    # optionally, sending the credentials to authenticate using the credentials.
                    # this is for fetching from private repositories that require WWW-Authenticate
                    auth = {url: pattern},
                    allow_fail = allow_fail,
                )
                if allow_fail and not result.success:
                    return {}

            auth_raw = rctx.read("www-authenticate.json")
            auth = json.decode(auth_raw)

            token = ""
            if "token" in auth:
                token = auth["token"]
            if "access_token" in auth:
                token = auth["access_token"]
            if token == "":
                if allow_fail:
                    return {}
                fail("could not find token in neither field 'token' nor 'access_token' in the response from the registry")
            pattern = {
                "type": "pattern",
                "pattern": "Bearer <password>",
                "password": token,
            }

            # put the token into cache so that we don't do the token exchange again.
            state["token"][url] = pattern
    return pattern

NO_CONFIG_FOUND_ERROR = """\
Could not find the `$HOME/.docker/config.json` and `$XDG_RUNTIME_DIR/containers/auth.json` file

Running one of `podman login`, `docker login`, `crane login` may help.
"""

def _explain(state):
    if not state["config"]:
        return NO_CONFIG_FOUND_ERROR
    return None

def _new_auth(rctx, config_path = None):
    if not config_path:
        config_path = _get_auth_file_path(rctx)
    config = {}
    if config_path:
        config = json.decode(rctx.read(config_path))
    state = {
        "config": config,
        "auth": {},
        "token": {},
    }
    return struct(
        get_token = lambda reg, repo: _get_token(rctx, state, reg, repo),
        explain = lambda: _explain(state),
    )

authn = struct(
    new = _new_auth,
    ENVIRON = [
        "DOCKER_CONFIG",
        "REGISTRY_AUTH_FILE",
        "XDG_RUNTIME_DIR",
        "HOME",
        "OCI_ENABLE_OAUTH2_SUPPORT",
    ],
)
