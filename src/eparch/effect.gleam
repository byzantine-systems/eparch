//// Transition descriptions for the logical-clock interpreter in `eparch/machine`.
////
//// An `Effect` value is a *description* of what a transition wants the
//// runtime to do. Descriptions are pure data: building one does nothing.
//// The OTP wrapper in `eparch/state_machine` has its own action type.
////
//// ## The algebra
////
//// Effect lists form a monoid under concatenation: `[]` is the identity and
//// regrouping changes nothing, because interpretation is order-preserving.
//// `resolve` normalises a list the same way the `gen_statem` engine does:
//// for each timer class (state, event, or a given generic id) the **last**
//// arming, cancelling, or updating decision wins, and everything else keeps
//// its relative order. This gives two laws that `test/effect_property_test`
//// checks for generated effect lists:
////
//// ```text
//// resolve(resolve(es)) == resolve(es)
//// resolve(a <> b)      == resolve(resolve(a) <> resolve(b))
//// ```
////
//// Timer decisions only resolve *within* a single transition's effect list.
//// Splitting one callback into two is not equivalent: the engine may enter
//// states, retry postponed events, or cancel timers between them.
////

import eparch/state_machine
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set

/// The address for replying to a synchronous call.
///
/// Values only ever originate from a `Call` input delivered by a runtime.
/// The phantom `reply` parameter ties a `From` to the one response type it
/// accepts, so `Reply(to, response)` is well-typed by construction.
///
pub type From(reply) =
  state_machine.From(reply)

/// An opaque identity for a named (generic) timer.
///
/// Distinct from the timer's payload: two `GenericTimeout` effects with the
/// same `TimerId` address the *same* timer, whatever content they carry.
/// Create one with `timer_id` and reuse the value; the runtime never inspects
/// the string beyond using it as the key.
///
pub opaque type TimerId {
  TimerId(name: String)
}

/// Create a `TimerId` for a named (generic) timer.
///
/// The name only has to be unique within one machine. Reusing the same
/// `timer_id(...)` value for the same conceptual timer is the intended use.
///
/// ## Example
///
/// ```gleam
/// let heartbeat = effect.timer_id("heartbeat")
/// effect.GenericTimeout(heartbeat, effect.After(1000), Beat)
/// ```
///
pub fn timer_id(name: String) -> TimerId {
  TimerId(name)
}

/// The string key underlying a `TimerId`, for display and interop.
///
/// ## Example
///
/// ```gleam
/// effect.timer_id("heartbeat") |> effect.timer_id_to_string
/// // -> "heartbeat"
/// ```
///
pub fn timer_id_to_string(id: TimerId) -> String {
  let TimerId(name) = id
  name
}

/// When a timer should fire.
///
/// - `After(ms)`: relative delay from the moment the effect is interpreted.
/// - `At(deadline)`: absolute deadline on the runtime's monotonic clock,
///   mapping to `gen_statem`'s `[{abs, true}]` timeout option.
///
pub type TimeoutTime {
  After(milliseconds: Int)
  At(monotonic_milliseconds: Int)
}

/// Negative relative delays mean immediately. Absolute monotonic readings
/// are signed and must retain their epoch, including negative timestamps.
@internal
pub fn normalise_time(time: TimeoutTime) -> TimeoutTime {
  case time {
    After(delay) -> After(int.max(0, delay))
    At(_) -> time
  }
}

/// The absolute deadline a `TimeoutTime` represents for the given clock
/// reading.
///
@internal
pub fn deadline_from(clock: Int, time: TimeoutTime) -> Int {
  case normalise_time(time) {
    After(ms) -> clock + ms
    At(deadline) -> deadline
  }
}

/// One transition effect.
///
/// Handlers build ordinary lists in execution order. Use `resolve` to
/// inspect which timer decisions survive a single transition.
///
pub type Effect(msg, reply) {
  /// Reply to a synchronous caller.
  Reply(to: From(reply), response: reply)

  /// Postpone the current input until after the next state change.
  Postpone

  /// Insert an event to be handled before any new external input.
  NextEvent(kind: NextEventKind(reply), content: msg)

  /// Arm the state timer, canceled by the next state change.
  StateTimeout(after: TimeoutTime, content: msg)

  /// Arm the event timer, canceled by any other input.
  EventTimeout(after: TimeoutTime, content: msg)

  /// Arm a named timer that persists across state changes.
  GenericTimeout(id: TimerId, after: TimeoutTime, content: msg)

  /// Cancel the running state timer.
  CancelStateTimeout

  /// Cancel the running event timer.
  CancelEventTimeout

  /// Cancel the named timer `id`.
  CancelGenericTimeout(id: TimerId)

  /// Change the payload of the running state timer without restarting it.
  /// If no state timer is running this fires immediately, exactly as a
  /// zero-delay arming does.
  UpdateStateTimeout(content: msg)

  /// Event timers are implicitly canceled on delivery, before new actions.
  UpdateEventTimeout(content: msg)

  /// Change the payload of the named timer `id` without restarting it.
  /// If it is not running this fires immediately.
  UpdateGenericTimeout(id: TimerId, content: msg)

  /// Hibernate the runtime process after this transition.
  Hibernate
}

/// Which kind of event a `NextEvent` effect inserts.
///
pub type NextEventKind(reply) {
  /// An internal event: only ever producible by the machine itself.
  InternalEvent
  /// Delivered as if cast from outside.
  CastEvent
  /// Delivered as if sent to the process mailbox.
  InfoEvent
  /// Delivered as a synchronous call from `from`.
  CallEvent(from: From(reply))
}

/// Which timer class an armed timer belongs to.
///
pub type TimerKind {
  StateTimer
  EventTimer
  GenericTimer(id: TimerId)
}

/// Actions legal in a state-enter callback. There is no current event to
/// postpone, and OTP rejects inserting a next event during entry.
pub type EntryEffect(msg, reply) {
  EntryReply(to: From(reply), response: reply)
  EntryArm(kind: TimerKind, time: TimeoutTime, content: msg)
  EntryCancel(kind: TimerKind)
  EntryUpdate(kind: TimerKind, content: msg)
  EntryHibernate
}

/// Embed an entry-safe effect into the full effect vocabulary. Every timer
/// decision keeps its timer class.
@internal
pub fn from_entry(entry: EntryEffect(msg, reply)) -> Effect(msg, reply) {
  case entry {
    EntryReply(to, response) -> Reply(to, response)
    EntryArm(StateTimer, t, m) -> StateTimeout(t, m)
    EntryArm(EventTimer, t, m) -> EventTimeout(t, m)
    EntryArm(GenericTimer(id), t, m) -> GenericTimeout(id, t, m)
    EntryCancel(StateTimer) -> CancelStateTimeout
    EntryCancel(EventTimer) -> CancelEventTimeout
    EntryCancel(GenericTimer(id)) -> CancelGenericTimeout(id)
    EntryUpdate(StateTimer, m) -> UpdateStateTimeout(m)
    EntryUpdate(EventTimer, m) -> UpdateEventTimeout(m)
    EntryUpdate(GenericTimer(id), m) -> UpdateGenericTimeout(id, m)
    EntryHibernate -> Hibernate
  }
}

/// Does this effect decide the fate of the given timer class?
///
@internal
pub fn decides_timer(effect: Effect(msg, reply), kind: TimerKind) -> Bool {
  decided_key(effect) == Some(kind)
}

/// Normalise an effect list the way the runtime engine does.
///
/// For each timer class the last decision wins: a later `StateTimeout`,
/// `CancelStateTimeout`, or `UpdateStateTimeout` overrides any earlier one
/// for that class, so at most one effect per timer class survives. Every
/// other effect keeps its order and position. The result is stable:
/// resolving an already-resolved list changes nothing, and resolving a
/// concatenation agrees with resolving the parts first.
///
/// ## Example
///
/// ```gleam
/// effect.resolve([
///   effect.StateTimeout(effect.After(10), First),
///   effect.Postpone,
///   effect.CancelStateTimeout,
/// ])
/// // -> [effect.Postpone, effect.CancelStateTimeout]
/// ```
///
pub fn resolve(effects: List(Effect(msg, reply))) -> List(Effect(msg, reply)) {
  let #(resolved, _) =
    list.fold_right(effects, #([], set.new()), fn(acc, effect) {
      let #(kept, decided) = acc
      case decided_key(effect) {
        Some(key) -> {
          case set.contains(decided, key) {
            True -> #(kept, decided)
            False -> #([effect, ..kept], set.insert(decided, key))
          }
        }
        None -> #([effect, ..kept], decided)
      }
    })
  resolved
}

fn decided_key(effect: Effect(msg, reply)) -> Option(TimerKind) {
  case effect {
    StateTimeout(..) | CancelStateTimeout | UpdateStateTimeout(_) ->
      Some(StateTimer)
    EventTimeout(..) | CancelEventTimeout | UpdateEventTimeout(_) ->
      Some(EventTimer)
    GenericTimeout(id, ..)
    | CancelGenericTimeout(id)
    | UpdateGenericTimeout(id, _) -> Some(GenericTimer(id))
    NextEvent(..) | Postpone | Hibernate | Reply(..) -> None
  }
}
