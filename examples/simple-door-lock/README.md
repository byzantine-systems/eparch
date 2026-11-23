# Door Lock

Door Lock example for `eparch/state_machine`, based on the [OTP Door Lock example](https://www.erlang.org/doc/system/statem.html#example).

```mermaid
stateDiagram
    Locked --> Open   : last digit of the code
    Locked --> Locked : next expected digit, or wrong digit (reset)
    Open   --> Locked : 5-second timeout
```

The machine matches keypad digits against the code one at a time. A correct digit advances to the next one; a wrong digit resets to the start of the code. Entering `Locked` resets the expected digits, and entering `Open` arms the auto-lock state timeout. Buttons pressed while open are ignored and do not restart it.

The default auto-lock delay is 5 seconds. `start_with_lock_timeout` permits a different delay, primarily for integration tests. An empty code is accepted but can never open the lock.

## Usage

```gleam
import doorlock

pub fn main() {
  let assert Ok(machine) = doorlock.start([1, 2, 3, 4])

  doorlock.get_status(machine.ref) // Locked
  doorlock.enter_code(machine.ref, [0, 0, 0, 0]) // returns Nil asynchronously
  doorlock.enter_code(machine.ref, [1, 2, 3, 4]) // returns Nil asynchronously
  doorlock.get_status(machine.ref) // Open
  // After 5 seconds the door auto-locks back to Locked.
}
```
