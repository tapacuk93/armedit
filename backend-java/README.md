# armeditd

The armedit backend: Java 25 on Netty, matching the stack aicoin-proxy runs.

## Building

The server is Netty, so unlike the rest of armedit this half has a dependency
and needs a build tool. Gradle 9.6.1, same as aicoin-proxy:

```
# borrow the wrapper from the sibling project, once
cp ~/src/aicoin/aicoin-proxy/gradlew .
mkdir -p gradle/wrapper && cp ~/src/aicoin/aicoin-proxy/gradle/wrapper/* gradle/wrapper/

./gradlew run
```

or with a system Gradle (`brew install gradle`):

```
gradle run
```

The wrapper is not committed here because it is a binary; borrowing it from
the project it was generated for keeps both on the same Gradle.

## Configuration

Everything is environment. Nothing is committed, and no credential of any kind
belongs in this repository.

| variable | meaning |
|---|---|
| `ARMEDIT_PORT` | listen port (default 8080) |
| `ARMEDIT_PUBLIC_ADDR` | the address baked into issued keys |
| `ARMEDIT_AICOIN` | aicoin proxy base URL |
| `ARMEDIT_PROVIDER` | default provider aicoin routes to |
| `ARMEDIT_MODEL` | default model override |
| `ARMEDIT_AWS_ADDR` | EC2 endpoint override, for a local or proxied endpoint |
| `ARMEDIT_AMI` | image the account's instance runs |
| `ARMEDIT_INSTANCE_TYPE` | default `t4g.small` |
| `ARMEDIT_WORKSPACE` | where accounts' folders live |
| `ARMEDIT_S3_BUCKET` | third tier of persistence |
| `ARMEDIT_IDLE_MINUTES` | terminate an idle account's instance (0 disables) |
| `ARMEDIT_REAP_SECONDS` | how often to sweep |

## Shape

| file | what it does |
|---|---|
| `Armeditd.java` | Netty transport and routing; every route on a virtual thread |
| `Accounts.java` | the account store and the one key that leaves the process |
| `Aicoin.java` | the route to a model, through the account's wallet |
| `Router.java` | which model answers, and model-to-model handoff |
| `Aws.java` | SigV4, EC2 provisioning, and signed calls to other services |
| `AwsPolicy.java` | what the model may ask AWS to do |
| `AwsAgent.java` | the action loop: judge, sign, run, redact, audit |
| `Clouds.java` | credentials for every bound cloud, and choosing between them |
| `Workspace.java` | memory to disk to cloud, per account and per screen |
| `Journal.java` | every edit including removals, and every gesture |
| `Otp.java` | the pad and the bit ledger |
| `Page.java` | the registration page |
| `Json.java` | just enough JSON for this protocol |

## Threading

Netty's event loops never block. Every route runs on a virtual thread and
writes its response back from there, which Netty permits. This matters because
a single `Cmd`+`P` can sit upstream for minutes: on the event loop that would
stall every other connection the process is serving.
