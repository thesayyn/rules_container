# Dockerfile + rules_oci

STOP before committing this atrocity. Here's some good reasons why you should not do what we have done here.

- Dockerfiles are fundamentally non-reproducible
- Reproducible builds are important for Bazel, Dockerfiles will lead to poor cache hits.
- `RUN` instruction is a perfect foot-gun for non-reprocubile builds, a simple command `RUN apt-get install curl` is non-hermetic by default.
- Building the same Dockerfile one month apart will yield different results.
- `FROM python:3.11.9-bullseye` is non-producible.

So you have chosen to walk this path... one thing that can be tricky is to get Bazel artifacts into the build context of Docker. Docker does not like symlinks or backtracking out of the build context. However, we can provide a complete context using [a tar file and piping it into BuildX](https://docs.docker.com/build/concepts/context/#local-tarballs). Since we have full control over tar layout in Bazel, we now have full control over the build context!

This technique offers an easy migration path from `container_run_and_commit` in `rules_docker`, but use it sparingly.

# Resources

- https://reproducible-builds.org/
- https://github.com/bazel-contrib/rules_oci/issues/35#issuecomment-1285954483
- https://github.com/bazel-contrib/rules_oci/blob/main/docs/compare_dockerfile.md
- https://github.com/moby/moby/issues/43124
- https://medium.com/nttlabs/bit-for-bit-reproducible-builds-with-dockerfile-7cc2b9faed9f
