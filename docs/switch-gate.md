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

## Operating rules

1. One release is armed at a time. The gate holds a single operation id, and arming another replaces it.
2. Disarm in the same Safe transaction as a cancel. A cancelled operation stays armed on the gate, and the same batch scheduled again with the same salt would already be armed.
3. Once an armed batch is ready, the guardian's pause is the only fast stop. Disarming and cancelling take both owners' signatures.

## On a fork

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

```sh
forge script script/DeploySwitchGate.s.sol --rpc-url $ETH_RPC_URL
```

This simulates the deployment and sends nothing. It prints the gate's address and each constructor argument:

```
SwitchGate 0x...
safe 0xdFeFbdBF680568e8DC44abbbd657c0701964cC8c
timelock 0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e
operator 0x1111111111111111111111111111111111111111
guardian 0x2222222222222222222222222222222222222222
log 0x2EF509bd9cA1e7C5FBe2C2FD7Ff25cE9F6f9cB68
log 0x53e0137e45C8bAc1018802aD36060cDda3B159F0
```

The script refuses an operator or guardian that is zero, equal to the Safe or equal to each other, and a log the timelock does not own. To deploy on the fork, add `--broadcast --unlocked --sender $DEPLOYER`; it prints the same lines. On BrainChain, use the deployer's keystore as the script's header shows. Then:

```sh
GATE=<the SwitchGate address>
cast call $GATE "armed()(bytes32)"
```

prints `0x0000000000000000000000000000000000000000000000000000000000000000`: nothing is armed.

### Grant the executor role

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
PAYLOADS="[$ALLOW,$ALLOW]"
SALT=$(cast keccak "example release")
cast send $TIMELOCK "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)" \
  $TARGETS "[0,0]" $PAYLOADS $ZERO $SALT 172800 --unlocked --from $SAFE
OP=$(cast call $TIMELOCK "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)" \
  $TARGETS "[0,0]" $PAYLOADS $ZERO $SALT)
```

`OP` is the operation id. For a release the Safe already scheduled, take the targets, calldata, predecessor and salt from the Safe transaction that scheduled it; `hashOperationBatch` on them must print the operation id. The Safe arms it:

```sh
cast send $GATE "arm(bytes32)" $OP --unlocked --from $SAFE
cast call $GATE "armed()(bytes32)"
```

The last line prints the operation id. Any other sender gets `NotSafe`. `arm` with `$ZERO` disarms, at any time.

Arming needs the operation scheduled first. `arm` refuses an id the timelock does not hold as pending (never scheduled, cancelled or already run), and `cast send` prints `Error: Failed to estimate gas` ending in `NotPending(<id>)`. On BrainChain the Safe can schedule and arm in one Safe transaction, as a batch of two calls with the schedule call first.

### Execute it as the operator

Once the delay has passed:

```sh
cast rpc evm_increaseTime 172800 && cast rpc evm_mine
cast send $GATE "execute(address[],bytes[],bytes32,bytes32)" $TARGETS $PAYLOADS $ZERO $SALT \
  --unlocked --from $OPERATOR
cast call $TIMELOCK "isOperationDone(bytes32)(bool)" $OP
cast call $LOG_350 "allowedApp(bytes32)(bool)" $APP
cast call $GATE "armed()(bytes32)"
```

`execute` takes no values: the gate always passes zero. The three calls print `true`, `true` and the zero id, because a successful execute clears the armed id. A failed execute leaves it armed.

The gate refuses with:

| Error | Why |
| --- | --- |
| `NotAllowed` | The sender is neither the operator nor the Safe |
| `IsPaused` | The guardian or the Safe paused the gate |
| `BadBatch` | No calls, or a different number of targets and calldata |
| `ForbiddenTarget(i)` | Call `i` goes to an address that is not a listed log |
| `ForbiddenCall(i)` | Call `i` is not 68 bytes of `allowApp` or `allowImage` |
| `NotArmed(id)` | The batch's operation id is not the armed one |
| `TimelockUnexpectedOperationState(id, ...)` | The timelock's own refusal: never scheduled, still waiting, or already run |

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
```

The second line prints the new address. The old key loses its right in the same block. `setGuardian(address)` replaces the guardian the same way. Both take only the Safe.

### List or delist a log

```sh
cast send $GATE "setLog(address,bool)" $LOG_360 false --unlocked --from $SAFE
cast call $GATE "isLog(address)(bool)" $LOG_360
cast send $GATE "setLog(address,bool)" $LOG_360 true --unlocked --from $SAFE
cast call $GATE "isLog(address)(bool)" $LOG_360
```

The two calls print `false`, then `true`. Listing needs a contract whose `owner()` is the timelock. An address without code, or a contract owned by anyone else, fails with `NotTimelockOwned(<address>)`. A contract without an `owner()` function fails with no reason. Delisting works for any address.

### Take the role away

The Safe schedules the revoke and executes it 48 hours later:

```sh
REVOKE=$(cast calldata "revokeRole(bytes32,address)" $EXECUTOR_ROLE $GATE)
REVOKE_SALT=$(cast keccak "switch gate: revoke the executor role")
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $TIMELOCK 0 $REVOKE $ZERO $REVOKE_SALT 172800 --unlocked --from $SAFE
cast rpc evm_increaseTime 172800 && cast rpc evm_mine
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $TIMELOCK 0 $REVOKE $ZERO $REVOKE_SALT --unlocked --from $SAFE
cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $EXECUTOR_ROLE $GATE
```

The last line prints `false`. The gate has no way to give the role up itself. While the revoke waits out its delay, the guardian pauses the gate and the Safe disarms it.
