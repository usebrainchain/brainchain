# Switch gate

A new enclave release needs one admin operation on the AdminTimelock, `0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e`: a batch that allows the new enclave's app or OS image on both decision logs and drops the old one. The admin Safe schedules it, and 48 hours later the Safe executes it. That is two rounds of signatures from both owners for every release.

[`SwitchGate`](../src/SwitchGate.sol) takes the second round. It holds the timelock's executor role, and nothing else. The Safe arms one scheduled batch on the gate by its operation id, and the guard's operator key executes it through the gate once its delay has passed. The gate refuses any batch that is not armed, and any batch with a call other than `allowApp(bytes32,bool)` or `allowImage(bytes32,bool)` on a listed decision log.

The gate is not deployed yet. Every step below runs on a local fork of BrainChain.

## What a leaked operator key can and cannot do

The operator can execute the one batch the Safe armed, once, at any time after its delay has passed.

The operator cannot:

- execute a batch the Safe did not arm, or arm one;
- execute a second batch after the armed one has run;
- call anything other than `allowApp` or `allowImage` on a listed log, or send value;
- schedule or cancel an operation, grant or revoke a role, or change the delay;
- pause, unpause, or change the operator, the guardian or the logs.

The operator chooses the moment. If it runs a release before the new enclave is up, the current brain keeps its seat, because dropping an app does not unseat the brain. If the old enclave then restarts with a new key, nobody holds the brain seat until the new enclave attests or the Safe names a brain with `setBrain` through the timelock, which takes 48 hours.

## What the gate checks

- A listed log must answer like a `DecisionLog`. It needs code, and its `owner()`, `allowedApp(bytes32)` and `allowedImage(bytes32)` must answer. Otherwise listing fails with `NotADecisionLog(<log>)`. An owner other than the timelock fails with `NotTimelockOwned(<log>)`. A contract that imitates those three views and names the timelock as its owner still passes, so the Safe lists only the real decision logs.
- Arming accepts any pending operation id. Only a batch of `allowApp` and `allowImage` calls on listed logs, scheduled with `scheduleBatch` and zero values, can execute.
- An arming holds for one scheduling. The gate records the operation's ready time when the Safe arms it. If the Safe cancels the batch and schedules it again, the ready time changes, and `execute` fails with `NotArmed(<id>)` until the Safe arms it again. A cancel and a new schedule in the same block with the same delay keep the ready time, and with it the arming.
- The operator and the guardian are always different keys. The contract refuses the same key with `SameKey` when it is deployed and in `setOperator` and `setGuardian`. A zero operator is allowed: it switches the operator off.

## Operating rules

1. One release is armed at a time. The gate holds a single operation id, and arming another replaces it.
2. Disarm in the same Safe transaction as a cancel. A cancel leaves the id in the slot, and a new schedule of the same batch in the same block with the same delay would still be armed.
3. Once an armed batch is ready, the guardian's pause is the only fast stop. Disarming and cancelling take both owners' signatures. A pause must land before the execute. It does not undo one.

The Safe keeps its own executor role on the timelock. The gate's pause stops only the gate: the Safe can still execute any ready operation directly on the timelock.

## On a fork

The commands need Foundry. In the repository root, run `git submodule update --init` and `forge build` once.

Start a fork that lets any address send:

```sh
anvil --fork-url https://rpc.usebrainchain.com --auto-impersonate
```

In a second terminal, from the repository root:

```sh
export ETH_RPC_URL=http://127.0.0.1:8545
export SAFE=0xdFeFbdBF680568e8DC44abbbd657c0701964cC8c
export TIMELOCK=0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e
export OPERATOR=0x1111111111111111111111111111111111111111
export GUARDIAN=0x2222222222222222222222222222222222222222
LOG_350=0x2EF509bd9cA1e7C5FBe2C2FD7Ff25cE9F6f9cB68
LOG_360=0x53e0137e45C8bAc1018802aD36060cDda3B159F0
export LOGS=$LOG_350,$LOG_360
DEPLOYER=0x3333333333333333333333333333333333333333
ZERO=0x0000000000000000000000000000000000000000000000000000000000000000
EXECUTOR_ROLE=$(cast keccak EXECUTOR_ROLE)
for a in $SAFE $OPERATOR $GUARDIAN $DEPLOYER; do cast rpc anvil_setBalance $a 0xDE0B6B3A7640000; done
```

Each `anvil_setBalance` prints `null`. The operator, guardian and deployer are made-up addresses. On the fork, `--unlocked --from $SAFE` stands in for a Safe transaction. On BrainChain the owners sign the same call in the Safe app.

Each `cast send` below prints a receipt with `status 1 (success)` when it works. A refused call prints `Error: Failed to estimate gas` followed by the error's name.

### Deploy

Simulate first. This sends nothing:

```sh
forge script script/DeploySwitchGate.s.sol --rpc-url $ETH_RPC_URL
```

It prints an address and each constructor argument:

```
SwitchGate 0x...
safe 0xdFeFbdBF680568e8DC44abbbd657c0701964cC8c
timelock 0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e
operator 0x1111111111111111111111111111111111111111
guardian 0x2222222222222222222222222222222222222222
log 0x2EF509bd9cA1e7C5FBe2C2FD7Ff25cE9F6f9cB68
log 0x53e0137e45C8bAc1018802aD36060cDda3B159F0
```

The simulation runs from forge's default sender, so its address is not the one a deployment gets. Deploy on the fork from the made-up deployer:

```sh
forge script script/DeploySwitchGate.s.sol --rpc-url $ETH_RPC_URL --broadcast --unlocked --sender $DEPLOYER
```

It prints the same lines with the real address, then `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.` Take the address from this output, or from `broadcast/DeploySwitchGate.s.sol/274663/run-latest.json`:

```sh
GATE=<the SwitchGate address from the deployment>
cast call $GATE "armed()(bytes32)"
```

The second line prints the zero id: nothing is armed.

On BrainChain the deployer key pays the gas and gets no power over the gate. Simulate without the last line, then deploy with it:

```sh
SAFE=0xdFeFbdBF680568e8DC44abbbd657c0701964cC8c \
TIMELOCK=0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e \
OPERATOR=<the guard's operator address> \
GUARDIAN=<the guardian's address> \
LOGS=0x2EF509bd9cA1e7C5FBe2C2FD7Ff25cE9F6f9cB68,0x53e0137e45C8bAc1018802aD36060cDda3B159F0 \
forge script script/DeploySwitchGate.s.sol --rpc-url https://rpc.usebrainchain.com \
  --keystore <deployer keystore file> --password-file <file with its password> --sender <deployer address> --broadcast
```

`LOGS` is comma-separated, without spaces. The script stops before deploying with one of these lines:

| Line | Cause |
| --- | --- |
| `Error: script failed: not BrainChain (274663): pass --rpc-url https://rpc.usebrainchain.com` | The RPC is another chain |
| `Error: script failed: SAFE has no code` | `SAFE` is not a contract |
| `Error: script failed: TIMELOCK has no code` | `TIMELOCK` is not a contract |
| `Error: script failed: SAFE is not the timelock's proposer` | `SAFE` cannot schedule on `TIMELOCK` |
| `Error: script failed: OPERATOR is zero or the Safe` | Pick another operator |
| `Error: script failed: GUARDIAN is zero or the Safe` | Pick another guardian |
| `Error: script failed: OPERATOR and GUARDIAN are the same key` | The two must differ |
| `Error: script failed: LOGS is empty` | `LOGS` names no log |
| `Error: script failed: NotADecisionLog(<log>)` | A log in `LOGS` has no code or does not answer like a `DecisionLog` |
| `Error: script failed: NotTimelockOwned(<log>)` | A log in `LOGS` has another owner |

### Grant the executor role

Check the timelock first. Its executor role must not be open to everyone, and the gate must hold no proposer or canceller role:

```sh
cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $EXECUTOR_ROLE 0x0000000000000000000000000000000000000000
cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $(cast keccak PROPOSER_ROLE) $GATE
cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $(cast keccak CANCELLER_ROLE) $GATE
```

All three print `false`. If the first prints `true`, anyone can execute a ready operation on the timelock, and the gate adds nothing.

The timelock is its own admin, so the grant is a timelock operation. The Safe schedules it:

```sh
GRANT=$(cast calldata "grantRole(bytes32,address)" $EXECUTOR_ROLE $GATE)
GRANT_SALT=$(cast keccak "switch gate: grant the executor role")
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $TIMELOCK 0 $GRANT $ZERO $GRANT_SALT 172800 --unlocked --from $SAFE
GRANT_ID=$(cast call $TIMELOCK "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
  $TIMELOCK 0 $GRANT $ZERO $GRANT_SALT)
```

For the Safe app, `cast calldata "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $TIMELOCK 0 $GRANT $ZERO $GRANT_SALT 172800` prints the data of a transaction to the timelock with zero value.

Executing before the delay is over fails with `TimelockUnexpectedOperationState(<GRANT_ID>, 0x...04)`. On the fork, move the clock 48 hours (`evm_increaseTime` prints the total offset in seconds, `evm_mine` prints `"0x0"`), then the Safe executes:

```sh
cast rpc evm_increaseTime 172800 && cast rpc evm_mine
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $TIMELOCK 0 $GRANT $ZERO $GRANT_SALT --unlocked --from $SAFE
cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $EXECUTOR_ROLE $GATE
```

The last line prints `true`.

### Arm a release

A release is a batch of `allowApp` and `allowImage` calls on the listed logs, with zero values, scheduled with `scheduleBatch`. The gate cannot run an operation scheduled with `schedule`, or one with a nonzero value. This one allows an example app on both logs:

```sh
APP=$(cast keccak "example app")
ALLOW=$(cast calldata "allowApp(bytes32,bool)" $APP true)
TARGETS="[$LOG_350,$LOG_360]"
VALUES="[0,0]"
PAYLOADS="[$ALLOW,$ALLOW]"
SALT=$(cast keccak "example release")
cast send $TIMELOCK "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)" \
  $TARGETS $VALUES $PAYLOADS $ZERO $SALT 172800 --unlocked --from $SAFE
OP=$(cast call $TIMELOCK "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)" \
  $TARGETS $VALUES $PAYLOADS $ZERO $SALT)
```

`OP` is the operation id. The Safe arms it:

```sh
cast send $GATE "arm(bytes32)" $OP --unlocked --from $SAFE
cast call $GATE "armed()(bytes32)"
```

The last line prints the operation id. Any other sender gets `NotSafe`. `arm` with `$ZERO` disarms, at any time.

Arming needs the operation scheduled first. `arm` refuses an id the timelock does not hold as pending (never scheduled, cancelled or already run), and `cast send` prints `Error: Failed to estimate gas` ending in `NotPending(<id>)`. On BrainChain the Safe can schedule and arm in one Safe transaction, as a batch of two calls with the schedule call first.

#### A release the Safe already scheduled

Each release's schedule script in brainchain-ops writes its batch to `ops/tee/mainnet-vNN-op.txt`, one line of seven fields separated by `|`: the targets, the values and the payloads (each as `[a,b,...]`), then the salt, the operation id, the OS image and the app. The predecessor is zero. Set `OPFILE` to the release's file in your brainchain-ops checkout, then read it and check the id:

```sh
IFS='|' read -r TARGETS VALUES PAYLOADS SALT OP IMAGE NEW_APP < "$OPFILE"
cast call $TIMELOCK "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)" \
  $TARGETS $VALUES $PAYLOADS $ZERO $SALT
cast call $TIMELOCK "isOperationPending(bytes32)(bool)" $OP
```

The first call must print the operation id the Safe scheduled, the same as `$OP`. The second prints `true` until the release runs or is cancelled. Arm `$OP` only when both hold, with the same `arm` command as above. On the fork this replaces the example batch in the slot.

Without the file, read the batch from the timelock's logs (this needs `jq`):

```sh
cast logs --from-block 1 --address $TIMELOCK --json \
  "CallScheduled(bytes32 indexed,uint256 indexed,address,uint256,bytes,bytes32,uint256)" $OP |
  jq -r '.[].data' | xargs -n1 cast abi-decode --input "x(address,uint256,bytes,bytes32,uint256)"
cast logs --from-block 1 --address $TIMELOCK --json "CallSalt(bytes32 indexed,bytes32)" $OP | jq -r '.[0].data'
```

The first command prints each call in order: its target, value, payload, predecessor and delay. The second prints the salt. A batch with a zero salt has no `CallSalt` log.

### Execute it as the operator

Once the delay has passed:

```sh
cast rpc evm_increaseTime 172800 && cast rpc evm_mine
cast send $GATE "execute(address[],bytes[],bytes32,bytes32)" $TARGETS $PAYLOADS $ZERO $SALT \
  --unlocked --from $OPERATOR
cast call $TIMELOCK "isOperationDone(bytes32)(bool)" $OP
cast call $GATE "armed()(bytes32)"
```

`execute` takes the targets, the payloads, the predecessor and the salt. It has no values argument: the gate always passes zero. The last two calls print `true` and the zero id, because a successful execute clears the armed id. A failed execute leaves it armed.

Then check every call of the batch on its log. Each payload is `allowApp` (selector `0x8bdea955`) or `allowImage` (selector `0x181abb99`), with an id and the value to set:

```sh
paste -d' ' <(echo $TARGETS | tr -d '[]' | tr ',' '\n') <(echo $PAYLOADS | tr -d '[]' | tr ',' '\n') |
while read -r log call; do
  case ${call:0:10} in
    0x8bdea955) view=allowedApp sig="allowApp(bytes32,bool)" ;;
    0x181abb99) view=allowedImage sig="allowImage(bytes32,bool)" ;;
  esac
  set -- $(cast calldata-decode $sig $call)
  echo "$log $view $1 set $2 now $(cast call $log "$view(bytes32)(bool)" $1)"
done
```

It prints one line per call. On every line the value after `set` and the value after `now` must match: `true` for the new app or image, `false` for the dropped one, on each listed log.

### Refusals

`execute` and `arm` refuse with:

| Error | Why |
| --- | --- |
| `NotAllowed` | The sender of `execute` is neither the operator nor the Safe |
| `NotSafe` | The sender of `arm` or a setting is not the Safe |
| `IsPaused` | The guardian or the Safe paused the gate |
| `BadBatch` | No calls, or a different number of targets and payloads |
| `ForbiddenTarget(i)` | Call `i` goes to an address that is not a listed log |
| `ForbiddenCall(i)` | Call `i` is not 68 bytes of `allowApp` or `allowImage` |
| `NotArmed(id)` | The batch's operation id is not the armed one, or the batch was cancelled or scheduled again since it was armed |
| `NotPending(id)` | `arm` was given an id the timelock does not hold as pending |
| `AccessControlUnauthorizedAccount(<gate>, <EXECUTOR_ROLE>)` | The gate does not hold the executor role: it was never granted, or it was revoked |
| `TimelockUnexpectedOperationState(id, ...)` | The armed batch is still waiting out its delay |
| No reason (`execution reverted, data: "0x"`) | `execute` was called with the timelock's five-argument shape, values included. The gate takes four |

To see why the timelock refused, read the operation's state:

```sh
cast call $TIMELOCK "isOperationPending(bytes32)(bool)" $OP
cast call $TIMELOCK "isOperationReady(bytes32)(bool)" $OP
cast call $TIMELOCK "isOperationDone(bytes32)(bool)" $OP
```

| Pending | Ready | Done | State |
| --- | --- | --- | --- |
| `true` | `false` | `false` | Still waiting out its delay |
| `true` | `true` | `false` | Ready to execute |
| `false` | `false` | `true` | Already executed |
| `false` | `false` | `false` | Never scheduled, or cancelled |

### Pause and unpause

The guardian pauses:

```sh
cast send $GATE "setPaused(bool,string)" true "v17 does not boot" --unlocked --from $GUARDIAN
cast call $GATE "paused()(bool)"
```

The second line prints `true`. While paused, `execute` fails with `IsPaused`, for the Safe as well. The guardian cannot unpause: `setPaused(false, ...)` from the guardian fails with `NotAllowed`. The Safe unpauses:

```sh
cast send $GATE "setPaused(bool,string)" false "reviewed" --unlocked --from $SAFE
cast call $GATE "paused()(bool)"
```

The second line prints `false`. The reason string is published in the `Paused` event.

### Replace the operator

```sh
cast send $GATE "setOperator(address)" 0x4444444444444444444444444444444444444444 --unlocked --from $SAFE
cast call $GATE "operator()(address)"
OPERATOR=0x4444444444444444444444444444444444444444
cast rpc anvil_setBalance $OPERATOR 0xDE0B6B3A7640000
```

The second line prints the new address. The old key loses its right in the same block. The last two lines point the shell's `$OPERATOR` at the new key and fund it on the fork; set `$OPERATOR` before any later command that sends from the operator. `setGuardian(address)` replaces the guardian the same way. Both take only the Safe, and both fail with `SameKey` if the new key is the other role's key.

### List or delist a log

```sh
cast send $GATE "setLog(address,bool)" $LOG_360 false --unlocked --from $SAFE
cast call $GATE "isLog(address)(bool)" $LOG_360
cast send $GATE "setLog(address,bool)" $LOG_360 true --unlocked --from $SAFE
cast call $GATE "isLog(address)(bool)" $LOG_360
```

The two calls print `false`, then `true`. An address without code, or a contract whose `owner()`, `allowedApp(bytes32)` or `allowedImage(bytes32)` does not answer, fails with `NotADecisionLog(<address>)`. A contract owned by anyone other than the timelock fails with `NotTimelockOwned(<address>)`. Delisting works for any address.

### Take the role away

The gate cannot give the role up itself. Removing it takes four steps:

1. The guardian pauses the gate, so nothing runs while the revoke waits:

   ```sh
   cast send $GATE "setPaused(bool,string)" true "removing the gate" --unlocked --from $GUARDIAN
   ```

2. The Safe disarms the gate and schedules the revoke. On BrainChain these are two calls in one Safe transaction:

   ```sh
   cast send $GATE "arm(bytes32)" $ZERO --unlocked --from $SAFE
   REVOKE=$(cast calldata "revokeRole(bytes32,address)" $EXECUTOR_ROLE $GATE)
   REVOKE_SALT=$(cast keccak "switch gate: revoke the executor role")
   cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
     $TIMELOCK 0 $REVOKE $ZERO $REVOKE_SALT 172800 --unlocked --from $SAFE
   ```

3. After 48 hours the Safe executes the revoke:

   ```sh
   cast rpc evm_increaseTime 172800 && cast rpc evm_mine
   cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
     $TIMELOCK 0 $REVOKE $ZERO $REVOKE_SALT --unlocked --from $SAFE
   ```

4. Check the result:

   ```sh
   cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $EXECUTOR_ROLE $GATE
   cast call $GATE "paused()(bool)"
   cast call $GATE "armed()(bytes32)"
   ```

   The three calls print `false`, `true` and the zero id.

The gate is left paused, disarmed and without the executor role. Its operator, guardian and logs stay as they were. If the Safe later unpauses and arms a batch, `execute` fails with `AccessControlUnauthorizedAccount` until the role is granted again, which takes another 48 hours.
