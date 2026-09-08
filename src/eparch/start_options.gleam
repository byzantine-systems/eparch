//// Shared option types for eparch behaviour modules (`state_machine` and
//// `event_manager`). These mirror the OTP start-option surface common to
//// `gen_statem`, `gen_event`, and `gen_server`: timeouts, debug flags, and
//// the subset of `erlang:spawn_opt/2` options that make sense for a
//// long-running server process.

/// A timeout: either a fixed number of milliseconds or `Infinity`.
pub type Timeout {
  Infinity
  Milliseconds(ms: Int)
}

/// Process priority for `SpawnPriority`.
pub type Priority {
  PriorityLow
  PriorityNormal
  PriorityHigh
  PriorityMax
}

/// Message queue storage mode for `SpawnMessageQueueData`.
pub type MessageQueueMode {
  OnHeap
  OffHeap
}

/// Flags for the `debug` start option.
pub type DebugFlag {
  DebugTrace
  DebugLog
  DebugStatistics
  /// Disabled by the Erlang FFI because a library cannot safely constrain the
  /// path or prevent symlink traversal. Configure file logging in the owning
  /// application instead.
  DebugLogToFile(file_name: String)
}

/// Subset of `erlang:spawn_opt/2`'s options that are meaningful for a
/// long-running server process. `link` and `monitor` are intentionally
/// omitted: they are decided by the lifecycle entry point (`start_link`,
/// `start`, `start_monitor`). Values must be positive (except
/// `SpawnFullsweepAfter`, which may be zero). The Erlang FFI installs a default
/// maximum heap of 8,388,608 words when this list has no maximum.
pub type SpawnOption {
  SpawnPriority(level: Priority)
  SpawnFullsweepAfter(count: Int)
  SpawnMinHeapSize(size: Int)
  SpawnMinBinVheapSize(size: Int)
  SpawnMaxHeapSize(size: Int)
  SpawnMessageQueueData(mode: MessageQueueMode)
}
