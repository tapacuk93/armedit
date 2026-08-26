## asmeditd, ahead-of-time compiled.
##
## Two stages: GraalVM's native-image toolchain runs the Gradle build and
## produces a real executable, then only that executable is copied onto a
## runtime base with no JVM on it at all.
##
## Why AOT rather than the JVM mode aicoin-proxy uses: this service spends most
## of its life idle and then has to answer a keystroke. A JVM pays for that
## shape twice - once in start-up before the first request, and again in the
## resident footprint of a runtime that is doing nothing between them. A native
## image starts in milliseconds and holds a fraction of the memory, which is
## what a per-user backend on a small host needs.
##
## The version pin: GraalVM has not published a JDK 26 build (checked Aug
## 2026), so 25 is the line. This tag, build.gradle's toolchain and
## .java-version must move together.

FROM ghcr.io/graalvm/native-image-community:25 AS build
WORKDIR /workspace

# Dependency resolution is cached separately from source changes, so editing a
# handler does not re-download Netty.
COPY gradlew gradlew.bat settings.gradle build.gradle ./
COPY gradle ./gradle
RUN ./gradlew --version --no-daemon

COPY src ./src
RUN ./gradlew nativeCompile --no-daemon

## Distroless rather than a slim distro: the binary is static enough to need
## only libc, and there is no shell, no package manager and no interpreter in
## the image for anything else to use. The JDK truststore is compiled into the
## binary, so outbound TLS to aicoin and AWS needs nothing from the OS.
FROM gcr.io/distroless/base-debian12 AS runtime
WORKDIR /opt/asmedit

COPY --from=build /workspace/build/native/nativeCompile/asmeditd /usr/local/bin/asmeditd

# Where accounts' folders live. Mount a volume here or everything typed is
# lost with the container.
VOLUME ["/opt/asmedit/workspaces"]
ENV ASMEDIT_WORKSPACE=/opt/asmedit/workspaces

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/asmeditd"]
