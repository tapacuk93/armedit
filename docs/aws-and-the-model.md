# Giving the model your AWS account without giving it your keys

The editor's whole point, once it is booted as an OS, is that you write
something down, press `Cmd`+`P`, and the machine does it — updates the list,
suggests something, quietly does nothing, or goes off and checks out a repo,
fixes a bug and publishes a build. That last one needs real access to real
infrastructure. So the question is not *whether* the model reaches AWS, but how
it does so without ever holding the credential.

## Why a key in a prompt is a published key

asmedit reaches models through aicoin, and aicoin multiplexes many users onto
**one shared provider API key**. That is the right design for billing — it is
why you never need your own Anthropic key — but it has a consequence worth
being blunt about:

- Everything in a prompt is seen by aicoin and by whichever provider it routes
  to, and is retained on their terms, not yours.
- Because the upstream account is shared, your traffic sits alongside other
  users' traffic in the same provider account. Any proxy bug that crosses two
  requests crosses them *inside* that account.
- Model output is not a secure channel either. Text that goes up can come back
  down — in a completion, in a cached prefix, in a log line.

An AWS access key that reaches any of that has not been shared carefully. It
has been disclosed. Rotating it later does not undo the disclosure.

So the rule this design is built on:

> **No AWS credential is ever placed in a prompt, a tool definition, a system
> message, or anything else that leaves this process.**

## What happens instead

The model is given a *capability*, not a *credential*. It is told that it can
ask for AWS operations by writing a line, and that the backend will run them
and show it the result:

```
#AWS ec2 DescribeInstances {"Filters":[{"Name":"instance-state-name","Values":["running"]}]}
```

The backend parses that line, decides whether it is allowed, signs the call
with the account's own credentials, executes it, strips anything secret-shaped
out of the reply, and feeds the result back as text. There is nothing in that
loop worth intercepting: the interesting half never leaves the machine holding
the keys.

This is the same trick aicoin itself plays one level down. The proxy injects
its own provider key so the client never has one; asmedit injects the account's
AWS key so the model never has one.

A plain-text action line rather than a provider's native tool-use format,
deliberately: aicoin fronts several providers whose tool formats differ, and a
format the backend parses itself is a format the backend can *refuse*.

## Three gates, not one

**Policy** (`AwsPolicy.java`). Every proposed action is judged before anything
is signed:

- *Reads run.* `Describe*`, `List*`, `Get*` and friends are reversible and are
  where nearly all agent work happens.
- *Writes are held.* Anything that changes infrastructure comes back to you as
  a confirmation, with the model's own explanation of what it would do.
- *Some things never run.* IAM, STS, Organizations and account APIs are refused
  outright, along with a short list of deletions that cannot be undone. An
  agent that can edit identity can grant itself everything else, which makes
  every other control here decorative.

**Session scope.** The same restrictions are expressed as an STS session policy
(`AwsPolicy.sessionPolicy()`), so when the backend assumes a role for a session
AWS itself enforces the ceiling. If the policy code above were bypassed
entirely, the cloud would still refuse. Two independent gates, not one gate
twice.

**Redaction.** Results are filtered before they travel back up to the provider.
This is not paranoia: EC2 `user-data` routinely contains bootstrap secrets, and
returning it verbatim would leak by accident exactly what we refused to send on
purpose. Key material, tokens, passwords and anything shaped like an access key
are replaced before the model sees them.

Every proposal — allowed, held or refused — is appended to `aws-audit.log` in
the account's own folder. An agent acting on infrastructure without a record of
what it asked for is not something anyone should run.

## What this does not protect against

Worth stating plainly:

- **A confused model is still a real actor.** Policy bounds what it can do, not
  whether it should. Anything held for confirmation is held because a human is
  the right judge of it.
- **Prompt injection reaches here.** If the model reads a file, a log line or a
  repository containing instructions, those instructions can propose AWS
  actions. That is precisely why reads are the only thing that runs unattended,
  and why the deny list is absolute rather than advisory.
- **The shared upstream key is still shared.** asmedit can keep secrets out of
  the prompt; it cannot make someone else's provider account private. Treat
  everything in a prompt as disclosed and the model's access as scoped, and
  neither assumption depends on the proxy behaving.

## Better credentials to hand the backend

Long-lived root keys work but are the weakest option. In rough order of
preference:

1. **A role to assume**, with a trust policy naming the backend's principal and
   an `ExternalId`. The backend holds nothing durable; sessions are minted
   short and scoped.
2. **A dedicated IAM user** with only the policy above attached, keys rotated
   on a schedule.
3. **Root or admin keys.** Accepted, because refusing them would just push
   people to paste them somewhere worse — but the policy gates are doing all
   the work in that case.
