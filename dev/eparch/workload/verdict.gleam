//// Oracle verdicts produced by the workload scenarios.
////
//// A verdict is one evaluated property: an `Always` claim that must hold
//// every time it is evaluated, or a `Sometimes` claim that must hold at
//// least once across runs. The Antithesis driver maps each verdict onto the
//// SDK assertion of the same name; `gleam test` asserts the `Always` ones
//// directly. Messages are the Antithesis property names, so each must be
//// unique and stable.

import gleam/int
import gleam/list
import gleam/string

pub type Kind {
  Always
  Sometimes
}

pub type Verdict {
  Verdict(kind: Kind, message: String, holds: Bool, details: String)
}

pub fn always(holds: Bool, message: String, details: String) -> Verdict {
  Verdict(Always, message, holds, details)
}

pub fn sometimes(holds: Bool, message: String, details: String) -> Verdict {
  Verdict(Sometimes, message, holds, details)
}

/// Every `Always` verdict that did not hold.
pub fn violations(verdicts: List(Verdict)) -> List(Verdict) {
  list.filter(verdicts, fn(verdict) { verdict.kind == Always && !verdict.holds })
}

/// One JSON object per verdict, for the line-oriented driver protocol.
pub fn to_json(verdict: Verdict) -> String {
  let kind = case verdict.kind {
    Always -> "always"
    Sometimes -> "sometimes"
  }
  let holds = case verdict.holds {
    True -> "true"
    False -> "false"
  }
  "{\"kind\":\""
  <> kind
  <> "\",\"message\":"
  <> json_string(verdict.message)
  <> ",\"holds\":"
  <> holds
  <> ",\"details\":"
  <> json_string(verdict.details)
  <> "}"
}

fn json_string(value: String) -> String {
  let escaped =
    value
    |> string.to_utf_codepoints
    |> list.map(escape)
    |> string.concat
  "\"" <> escaped <> "\""
}

fn escape(codepoint: UtfCodepoint) -> String {
  case string.utf_codepoint_to_int(codepoint) {
    0x22 -> "\\\""
    0x5C -> "\\\\"
    0x0A -> "\\n"
    0x0D -> "\\r"
    0x09 -> "\\t"
    code if code < 0x20 ->
      "\\u" <> string.pad_start(int.to_base16(code), to: 4, with: "0")
    _ -> string.from_utf_codepoints([codepoint])
  }
}
