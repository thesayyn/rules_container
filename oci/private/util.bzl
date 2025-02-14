"""Utilities"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//lib:versions.bzl", "versions")

_IMAGE_PLATFORM_VARIANT_DEFAULTS = {
    "linux/arm64": "v8",
}

def _parse_image(image):
    """Support syntax sugar in oci_pull where multiple data fields are in a single string, "image"

    Args:
        image: full-qualified reference url
    Returns:
        a tuple containing  scheme, registry, repository, digest, and tag information.
    """

    scheme = "https"
    digest = None
    tag = None

    if image.startswith("http://"):
        image = image[len("http://"):]
        scheme = "http"
    if image.startswith("https://"):
        image = image[len("https://"):]

    # Check syntax sugar for digest/tag suffix on image
    if image.rfind("@") > 0:
        image, digest = image.rsplit("@", 1)

    # Check if the last colon has no slashes after it.
    # Matches debian:latest and myregistry:8000/myimage:latest
    # but does not match myregistry:8000/myimage
    colon = image.rfind(":")
    if colon > 0 and image[colon:].find("/") == -1:
        image, tag = image.rsplit(":", 1)

    # Syntax sugar, special case for dockerhub
    if image.startswith("docker.io/"):
        image = "index." + image

    # If image has no repository, like bare "ubuntu" we assume it's dockerhub
    if image.find("/") == -1:
        image = "index.docker.io/library/" + image
    registry, repository = image.split("/", 1)

    return (scheme, registry, repository, digest, tag)

def _sha256(rctx, path):
    """Returns SHA256 hashsum of file at path

    Args:
        rctx: repository context
        path: path to the file
    Returns:
        hashsum of file
    """

    # Attempt to use the first viable method to calculate the SHA256 sum. sha256sum is part of
    # coreutils on Linux, but is not available on MacOS. shasum is a perl script that is available
    # on MacOS, but is not necessarily always available on Linux. OpenSSL is used as a final
    # fallback if neither are available
    result = rctx.execute(["shasum", "-a", "256", path])
    if result.return_code:
        result = rctx.execute(["sha256sum", path])
    if result.return_code:
        result = rctx.execute(["openssl", "sha256", "-r", path])
    if result.return_code:
        msg = "sha256 failed: \nSTDOUT:\n%s\nSTDERR:\n%s" % (result.stdout, result.stderr)
        fail(msg)

    return result.stdout.split(" ", 1)[0]

def _validate_image_platform(rctx, image_config):
    """Validate that the platform in the image config matches the requested platform attribute."""
    image_os = image_config.get("os", None)
    image_architecture = image_config.get("architecture", None)
    image_variant = image_config.get("variant", None)

    attr_os, attr_architecture, attr_variant = _platform_triplet(rctx.attr.platform)

    # the OCI spec makes os and architecture fields required but the Docker one doesn't specify.
    missing_fields = []
    if not image_os:
        missing_fields.append("os")
    elif image_os != attr_os:
        fail("Expected image {}/{} to have os '{}', got: '{}'".format(
            rctx.attr.registry,
            rctx.attr.repository,
            attr_os,
            image_os,
        ))
    if not image_architecture:
        missing_fields.append("architecture")
    elif image_architecture != attr_architecture:
        fail("Expected image {}/{} to have architecture '{}', got: '{}'".format(
            rctx.attr.registry,
            rctx.attr.repository,
            attr_architecture,
            image_architecture,
        ))

    if missing_fields:
        util.warning(rctx, "Could not confirm pulled image {}/{} is for platform {}: {} missing from image metadata".format(
            rctx.attr.registry,
            rctx.attr.repository,
            rctx.attr.platform,
            missing_fields,
        ))

    # contrary to os/arch, if the variant is set in the image metadata, it needs to be set in
    # the attribute or have a matching default.
    attr_variant_or_default = attr_variant or _IMAGE_PLATFORM_VARIANT_DEFAULTS.get(rctx.attr.platform, None)
    image_variant_or_default = image_variant or _IMAGE_PLATFORM_VARIANT_DEFAULTS.get(image_os + "/" + image_architecture, None)
    if image_variant_or_default != attr_variant_or_default:
        fail("Image {}/{} has platform variant '{}', but 'platforms' attribute specifies variant '{}'".format(
            rctx.attr.registry,
            rctx.attr.repository,
            image_variant,
            attr_variant,
        ))

def _warning(rctx, message):
    rctx.execute([
        "echo",
        "\033[0;33mWARNING:\033[0m {}".format(message),
    ], quiet = False)

def _maybe_wrap_launcher_for_windows(ctx, bash_launcher):
    """Windows cannot directly execute a shell script.

    Wrap with a .bat file that executes the shell script with a bash command.
    Based on create_windows_native_launcher_script from
    https://github.com/aspect-build/bazel-lib/blob/main/lib/windows_utils.bzl
    but without requiring that the script has a .runfiles folder.

    To use:
    - add the _windows_constraint appears in the rule attrs
    - make sure the bash_launcher is in the inputs to the action
    - @bazel_tools//tools/sh:toolchain_type should appear in the rules toolchains
    """
    if not ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]):
        return bash_launcher

    win_launcher = ctx.actions.declare_file("wrap_%s.bat" % ctx.label.name)
    ctx.actions.write(
        output = win_launcher,
        content = r"""@echo off
SETLOCAL ENABLEEXTENSIONS
SETLOCAL ENABLEDELAYEDEXPANSION
for %%a in ("{bash_bin}") do set "bash_bin_dir=%%~dpa"
set PATH=%bash_bin_dir%;%PATH%
set "parent_dir=%~dp0"
set "parent_dir=!parent_dir:\=/!"
set args=%*
rem Escape \ and * in args before passing it with double quote
if defined args (
  set args=!args:\=\\\\!
  set args=!args:"=\"!
)
"{bash_bin}" -c "%parent_dir%{launcher} !args!"
""".format(
            bash_bin = ctx.toolchains["@bazel_tools//tools/sh:toolchain_type"].path,
            launcher = paths.relativize(bash_launcher.path, win_launcher.dirname),
        ),
        is_executable = True,
    )

    return win_launcher

def _file_exists(rctx, path):
    result = rctx.execute(["stat", path])
    return result.return_code == 0

_INDEX_JSON_TMPL = """\
{{
   "schemaVersion": 2,
   "mediaType": "application/vnd.oci.image.index.v1+json",
   "manifests": [
      {{
         "mediaType": "{}",
         "size": {},
         "digest": "{}"{optional_platform}
      }}
   ]
}}"""

def _build_manifest_json(media_type, size, digest, platform):
    optional_platform = ""

    if platform:
        platform_parts = platform.split("/", 3)

        optional_variant = ""
        if len(platform_parts) == 3:
            optional_variant = ''',
            "variant": "{}"'''.format(platform_parts[2])

        optional_platform = """,
         "platform": {{
            "architecture": "{}",
            "os": "{}"{optional_variant}
         }}""".format(platform_parts[1], platform_parts[0], optional_variant = optional_variant)

    return _INDEX_JSON_TMPL.format(
        media_type,
        size,
        digest,
        optional_platform = optional_platform,
    )

def _assert_crane_version_at_least(ctx, at_least, rule):
    toolchain = ctx.toolchains["@rules_oci//oci:crane_toolchain_type"]
    if not versions.is_at_least(at_least, toolchain.crane_info.version):
        fail("rule {} requires crane version >={}".format(rule, at_least))

def _platform_triplet(platform_str):
    """Return the (os, architecture, variant) triplet corresponding to the oci platform string."""
    os, _, architecture = platform_str.partition("/")
    variant = None
    if "/" in architecture:
        architecture, _, variant = architecture.partition("/")
    return os, architecture, variant

# Helper rule for ensuring that the crane and yq toolchains are actually
# resolved for the architecture we are targeting.
def _transition_to_target_impl(settings, _attr):
    return {
        # String conversion is needed to prevent a crash with Bazel 6.x.
        "//command_line_option:extra_execution_platforms": [
            str(platform)
            for platform in settings["//command_line_option:platforms"]
        ],
    }

_transition_to_target = transition(
    implementation = _transition_to_target_impl,
    inputs = ["//command_line_option:platforms"],
    outputs = ["//command_line_option:extra_execution_platforms"],
)

util = struct(
    parse_image = _parse_image,
    sha256 = _sha256,
    validate_image_platform = _validate_image_platform,
    warning = _warning,
    maybe_wrap_launcher_for_windows = _maybe_wrap_launcher_for_windows,
    file_exists = _file_exists,
    build_manifest_json = _build_manifest_json,
    assert_crane_version_at_least = _assert_crane_version_at_least,
    platform_triplet = _platform_triplet,
    transition_to_target = _transition_to_target,
)
