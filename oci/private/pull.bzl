"Implementation details for oci_pull repository rules"

load("@aspect_bazel_lib//lib:base64.bzl", "base64")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("//oci/private:download.bzl", "download")
load("//oci/private:util.bzl", "sha256", "util")

# attributes that are specific to image reference url. shared between multiple targets
_IMAGE_REFERENCE_ATTRS = {
    "scheme": attr.string(
        doc = "scheme portion of the URL for fetching from the registry",
        values = ["http", "https"],
        default = "https",
    ),
    "registry": attr.string(
        doc = "Remote registry host to pull from, e.g. `gcr.io` or `index.docker.io`",
        mandatory = True,
    ),
    "repository": attr.string(
        doc = "Image path beneath the registry, e.g. `distroless/static`",
        mandatory = True,
    ),
    "identifier": attr.string(
        doc = "The digest or tag of the manifest file",
        mandatory = True,
    ),
    "config": attr.label(
        doc = "Label to a .docker/config.json file. by default this is generated by oci_auth_config in oci_register_toolchains macro.",
        default = "@oci_auth_config//:config.json",
        allow_single_file = True,
    ),
}

# Unfortunately bazel downloader doesn't let us sniff the WWW-Authenticate header, therefore we need to
# keep a map of known registries that require us to acquire a temporary token for authentication.
_WWW_AUTH = {
    "index.docker.io": {
        "realm": "auth.docker.io/token",
        "scope": "repository:{repository}:pull",
        "service": "registry.docker.io",
    },
    "public.ecr.aws": {
        "realm": "public.ecr.aws/token",
        "scope": "repository:{repository}:pull",
        "service": "public.ecr.aws",
    },
    "ghcr.io": {
        "realm": "ghcr.io/token",
        "scope": "repository:{repository}:pull",
        "service": "ghcr.io/token",
    },
}

def _strip_host(url):
    # TODO: a principled way of doing this
    return url.replace("http://", "").replace("https://", "").replace("/v1/", "")

def _get_auth(rctx, state, registry):
    # if we have a cached auth for this registry then just return it.
    # this will prevent repetitive calls to external cred helper binaries.
    if registry in state["auth"]:
        return state["auth"][registry]

    pattern = {}
    config = state["config"]

    if "auths" in config:
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
                    (login, password) = base64.decode(raw_auth).split(":")
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

                # cache the result so that we don't do this again unnecessarily.
                state["auth"][registry] = pattern

    return pattern

def _get_token(rctx, state, registry, repository):
    pattern = _get_auth(rctx, state, registry)

    if registry in _WWW_AUTH:
        www_authenticate = _WWW_AUTH[registry]
        url = "https://{realm}?scope={scope}&service={service}".format(
            realm = www_authenticate["realm"],
            service = www_authenticate["service"],
            scope = www_authenticate["scope"].format(repository = repository),
        )

        # if a token for this repository and registry is acquired, use that instead.
        if url in state["token"]:
            return state["token"][url]

        rctx.download(
            url = [url],
            output = "www-authenticate.json",
            # optionally, sending the credentials to authenticate using the credentials.
            # this is for fetching from private repositories that require WWW-Authenticate
            auth = {url: pattern},
        )
        auth_raw = rctx.read("www-authenticate.json")
        auth = json.decode(auth_raw)
        pattern = {
            "type": "pattern",
            "pattern": "Bearer <password>",
            "password": auth["token"],
        }

        # put the token into cache so that we don't do the token exchange again.
        state["token"][url] = pattern

    return pattern

def _fetch_auth_via_creds_helper(rctx, raw_host, helper_name):
    executable = "{}.sh".format(helper_name)
    rctx.file(
        executable,
        content = """\
#!/usr/bin/env bash
exec "docker-credential-{}" get <<< "$1"
        """.format(helper_name),
    )
    result = rctx.execute([rctx.path(executable), raw_host])
    if result.return_code:
        fail("credential helper failed: \nSTDOUT:\n{}\nSTDERR:\n{}".format(result.stdout, result.stderr))

    response = json.decode(result.stdout)

    if response["Username"] == "<token>":
        fail("Identity tokens are not supported at the moment. See: https://github.com/bazel-contrib/rules_oci/issues/129")

    return {
        "type": "basic",
        "login": response["Username"],
        "password": response["Secret"],
    }

# Supported media types
# * OCI spec: https://github.com/opencontainers/image-spec/blob/main/media-types.md
# * Docker spec: https://github.com/distribution/distribution/blob/main/docs/spec/manifest-v2-2.md#media-types
_SUPPORTED_MEDIA_TYPES = {
    "index": [
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.index.v1+json",
    ],
    "manifest": [
        "application/vnd.docker.distribution.manifest.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
    ],
}

def _is_tag(str):
    return str.find(":") == -1

def _trim_hash_algorithm(identifier):
    "Optionally remove the sha256: prefix from identifier, if present"
    parts = identifier.split(":", 1)
    if len(parts) != 2:
        return identifier
    return parts[1]

def _download(rctx, state, identifier, output, resource, download_fn = download.bazel, headers = {}, allow_fail = False):
    "Use the Bazel Downloader to fetch from the remote registry"

    if resource != "blobs" and resource != "manifests":
        fail("resource must be blobs or manifests")

    auth = _get_token(rctx, state, rctx.attr.registry, rctx.attr.repository)

    # Construct the URL to fetch from remote, see
    # https://github.com/google/go-containerregistry/blob/62f183e54939eabb8e80ad3dbc787d7e68e68a43/pkg/v1/remote/descriptor.go#L234
    registry_url = "{scheme}://{registry}/v2/{repository}/{resource}/{identifier}".format(
        scheme = rctx.attr.scheme,
        registry = rctx.attr.registry,
        repository = rctx.attr.repository,
        resource = resource,
        identifier = identifier,
    )

    # TODO(https://github.com/bazel-contrib/rules_oci/issues/73): other hash algorithms
    sha256 = ""

    if identifier.startswith("sha256:"):
        sha256 = identifier[len("sha256:"):]
    else:
        util.warning(rctx, """fetching from %s without an integrity hash. The result will not be cached.""" % registry_url)

    return download_fn(
        rctx,
        output = output,
        sha256 = sha256,
        url = registry_url,
        auth = {registry_url: auth},
        headers = headers,
        allow_fail = allow_fail,
    )

def _download_manifest(rctx, state, identifier, output):
    bytes = None
    manifest = None

    result = _download(rctx, state, identifier, output, "manifests", allow_fail = True)
    fallback_to_curl = False

    if result.success:
        bytes = rctx.read(output)
        manifest = json.decode(bytes)
        if manifest["schemaVersion"] == 1:
            util.warning(rctx, """\
registry responded with a manifest that has schemaVersion=1. Usually happens when fetching from a registry that requires `Docker-Distribution-API-Version` header to be set.
Falling back to using `curl`. See https://github.com/bazelbuild/bazel/issues/17829 for the context.""")
            fallback_to_curl = True
    else:
        util.warning(rctx, """\
Could not fetch the manifest. Either there was an authentication issue or trying to pull an image with OCI image media types. 
Falling back to using `curl`. See https://github.com/bazelbuild/bazel/issues/17829 for the context.""")
        fallback_to_curl = True

    if fallback_to_curl:
        _download(
            rctx,
            state,
            identifier,
            output,
            "manifests",
            download.curl,
            headers = {
                "Accept": ",".join(_SUPPORTED_MEDIA_TYPES["index"] + _SUPPORTED_MEDIA_TYPES["manifest"]),
                "Docker-Distribution-API-Version": "registry/2.0",
            },
        )
        bytes = rctx.read(output)
        manifest = json.decode(bytes)

    return manifest, len(bytes)

def _create_downloader(rctx):
    state = {
        "config": json.decode(rctx.read(rctx.attr.config)),
        "auth": {},
        "token": {},
    }
    return struct(
        download_blob = lambda identifier, output: _download(rctx, state, identifier, output, "blobs"),
        download_manifest = lambda identifier, output: _download_manifest(rctx, state, identifier, output),
    )

_build_file = """\
"Generated by oci_pull"

load("@aspect_bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")
load("@aspect_bazel_lib//lib:jq.bzl", "jq")
load("@bazel_skylib//rules:write_file.bzl", "write_file")

package(default_visibility = ["//visibility:public"])

# Mimic the output of crane pull [image] layout --format=oci
write_file(
    name = "write_layout",
    out = "oci-layout",
    content = [
        "{{",
        "    \\"imageLayoutVersion\\": \\"1.0.0\\"",
        "}}",
    ],
)

write_file(
    name = "write_index",
    out = "index.json",
    content = [\"\"\"{index_content}\"\"\"],
)

copy_to_directory(
    name = "blobs",
    # TODO(https://github.com/bazel-contrib/rules_oci/issues/73): other hash algorithms
    out = "blobs/sha256",
    include_external_repositories = ["*"],
    srcs = {tars} + [
        ":{manifest_file}",
        ":{config_file}",
    ],
)

copy_to_directory(
    name = "{target_name}",
    out = "layout",
    include_external_repositories = ["*"],
    srcs = [
        "blobs",
        "oci-layout",
        "index.json",
    ],
)
"""

def _find_platform_manifest(image_mf, platform_wanted):
    for mf in image_mf["manifests"]:
        parts = [
            mf["platform"]["os"],
            mf["platform"]["architecture"],
        ]
        if "variant" in mf["platform"]:
            parts.append(mf["platform"]["variant"])

        platform = "/".join(parts)
        if platform_wanted == platform:
            return mf
    return None

def _oci_pull_impl(rctx):
    downloader = _create_downloader(rctx)

    mf_file = _trim_hash_algorithm(rctx.attr.identifier)
    mf, mf_len = downloader.download_manifest(rctx.attr.identifier, mf_file)

    if mf["mediaType"] in _SUPPORTED_MEDIA_TYPES["manifest"]:
        if rctx.attr.platform:
            fail("{}/{} is a single-architecture image, so attribute 'platforms' should not be set.".format(rctx.attr.registry, rctx.attr.repository))
        image_mf_file = mf_file
        image_mf = mf
        image_mf_len = mf_len
        image_digest = rctx.attr.identifier
    elif mf["mediaType"] in _SUPPORTED_MEDIA_TYPES["index"]:
        # extra download to get the manifest for the selected arch
        if not rctx.attr.platform:
            fail("{}/{} is a multi-architecture image, so attribute 'platforms' is required.".format(rctx.attr.registry, rctx.attr.repository))
        matching_mf = _find_platform_manifest(mf, rctx.attr.platform)
        if not matching_mf:
            fail("No matching manifest found in image {}/{} for platform {}".format(rctx.attr.registry, rctx.attr.repository, rctx.attr.platform))
        image_digest = matching_mf["digest"]
        image_mf_file = _trim_hash_algorithm(image_digest)
        image_mf, image_mf_len = downloader.download_manifest(image_digest, image_mf_file)
    else:
        fail("Unrecognized mediaType {} in manifest file".format(mf["mediaType"]))

    image_config_file = _trim_hash_algorithm(image_mf["config"]["digest"])
    downloader.download_blob(image_mf["config"]["digest"], image_config_file)

    tars = []
    for layer in image_mf["layers"]:
        hash = _trim_hash_algorithm(layer["digest"])

        # TODO: we should avoid eager-download of the layers ("shallow pull")
        downloader.download_blob(layer["digest"], hash)
        tars.append(hash)

    # To make testing against `crane pull` simple, we take care to produce a byte-for-byte-identical
    # index.json file, which means we can't use jq (it produces a trailing newline) or starlark
    # json.encode_indent (it re-orders keys in the dictionary).
    if rctx.attr.platform:
        os, arch = rctx.attr.platform.split("/", 1)
        index_mf = """\
{
   "schemaVersion": 2,
   "mediaType": "application/vnd.oci.image.index.v1+json",
   "manifests": [
      {
         "mediaType": "%s",
         "size": %s,
         "digest": "%s",
         "platform": {
            "architecture": "%s",
            "os": "%s"
         }
      }
   ]
}""" % (image_mf["mediaType"], image_mf_len, image_digest, arch, os)
    else:
        index_mf = """\
{
   "schemaVersion": 2,
   "mediaType": "application/vnd.oci.image.index.v1+json",
   "manifests": [
      {
         "mediaType": "%s",
         "size": %s,
         "digest": "%s"
      }
   ]
}""" % (image_mf["mediaType"], image_mf_len, image_digest)

    rctx.file("BUILD.bazel", content = _build_file.format(
        target_name = rctx.attr.target_name,
        tars = tars,
        index_content = index_mf,
        manifest_file = image_mf_file,
        config_file = image_config_file,
    ))

oci_pull = repository_rule(
    implementation = _oci_pull_impl,
    attrs = dicts.add(
        _IMAGE_REFERENCE_ATTRS,
        {
            "platform": attr.string(
                doc = "A single platform in `os/arch` format, for multi-arch images",
            ),
            "target_name": attr.string(
                doc = "Name given for the image target, e.g. 'image'",
                mandatory = True,
            ),
        },
    ),
)

_MULTI_PLATFORM_IMAGE_ALIAS_TMPL = """\
alias(
    name = "{target_name}",
    actual = select(
        {platform_map}
    ),
    visibility = ["//visibility:public"],
)
"""

_SINGLE_PLATFORM_IMAGE_ALIAS_TMPL = """\
alias(
    name = "{target_name}",
    actual = "@{original}//:{original}",
    visibility = ["//visibility:public"],
)
"""

def _oci_alias_impl(rctx):
    if rctx.attr.platforms and rctx.attr.platform:
        fail("Only one of 'platforms' or 'platform' may be set")
    if not rctx.attr.platforms and not rctx.attr.platform:
        fail("One of 'platforms' or 'platform' must be set")

    downloader = _create_downloader(rctx)

    if _is_tag(rctx.attr.identifier) and rctx.attr.reproducible:
        manifest, _ = downloader.download_manifest(rctx.attr.identifier, "mf.json")
        digest = sha256(rctx, "mf.json")

        optional_platforms = ""

        if manifest["mediaType"] in _SUPPORTED_MEDIA_TYPES["index"]:
            platforms = []
            for submanifest in manifest["manifests"]:
                parts = [submanifest["platform"]["os"], submanifest["platform"]["architecture"]]
                if "variant" in submanifest["platform"]:
                    parts.append(submanifest["platform"]["variant"])
                platforms.append('"{}"'.format("/".join(parts)))
            optional_platforms = "'add platforms {}'".format(" ".join(platforms))

        util.warning(rctx, """\
for reproducible builds, a digest is recommended.
Either set 'reproducible = False' to silence this warning,
or run the following command to change oci_pull to use a digest:

buildozer 'set digest "sha256:{digest}"' 'remove tag' 'remove platforms' {optional_platforms} WORKSPACE:{name}
    """.format(
            name = rctx.attr.name,
            digest = digest,
            optional_platforms = optional_platforms,
        ))

    build = ""
    if rctx.attr.platforms:
        build = _MULTI_PLATFORM_IMAGE_ALIAS_TMPL.format(
            name = rctx.attr.name,
            target_name = rctx.attr.target_name,
            platform_map = {
                # Workaround bug in Bazel 6.1.0, see
                # https://github.com/bazel-contrib/rules_oci/issues/221
                str(k).replace("@@", "@"): v
                for k, v in rctx.attr.platforms.items()
            },
        )
    else:
        build = _SINGLE_PLATFORM_IMAGE_ALIAS_TMPL.format(
            name = rctx.attr.name,
            target_name = rctx.attr.target_name,
            original = rctx.attr.platform.name,
        )

    rctx.file("BUILD.bazel", content = build)

oci_alias = repository_rule(
    implementation = _oci_alias_impl,
    attrs = dicts.add(
        _IMAGE_REFERENCE_ATTRS,
        {
            "platforms": attr.label_keyed_string_dict(),
            "platform": attr.label(),
            "target_name": attr.string(),
            "reproducible": attr.bool(default = True, doc = "Set to False to silence the warning about reproducibility when using `tag`"),
        },
    ),
)
