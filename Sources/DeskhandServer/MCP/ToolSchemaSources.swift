enum ToolSchemaSources {
    static let files: [String: String] = [
        "defs.json": defs,
        "tools/displays.input.json": displaysInput,
        "tools/displays.output.json": displaysOutput,
        "tools/keyboard.input.json": keyboardInput,
        "tools/keyboard.output.json": keyboardOutput,
        "tools/lease.input.json": leaseInput,
        "tools/lease.output.json": leaseOutput,
        "tools/pointer.input.json": pointerInput,
        "tools/pointer.output.json": pointerOutput,
        "tools/screenshot.input.json": screenshotInput,
        "tools/screenshot.output.json": screenshotOutput,
        "tools/status.input.json": statusInput,
        "tools/status.output.json": statusOutput,
    ]

    static let defs = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/defs.json",
          "title": "deskhand shared definitions",
          "description": "Shared definitions for the deskhand wire contract (docs/contract.md, 0.11-draft). The $id is an identifier, not a location. Tool schemas reference these with ../defs.json#/$defs/NAME; tools/list serves each tool schema with these definitions copied into its own $defs.",
          "$comment": "Every string with a restricted alphabet carries both an anchored pattern and a not-pattern over the forbidden characters. In ECMA-262 the anchored pattern is enough, but in engines where $ also matches before a final line terminator (Python re, and ICU as used by NSRegularExpression) it would accept a trailing newline. The not-pattern closes that gap in every engine.",
          "$defs": {
            "state": {
              "description": "deskhand state, listed in precedence order (highest first). 'gated' is amendment 2 and is pending owner approval.",
              "type": "string",
              "enum": [
                "gated",
                "paused",
                "disarmed",
                "not_console",
                "locked",
                "display_asleep",
                "permission_missing",
                "permission_stale",
                "secure_input",
                "ok"
              ]
            },
            "blocking_state": {
              "description": "Any state other than 'ok', in precedence order.",
              "type": "string",
              "enum": [
                "gated",
                "paused",
                "disarmed",
                "not_console",
                "locked",
                "display_asleep",
                "permission_missing",
                "permission_stale",
                "secure_input"
              ]
            },
            "condition": {
              "description": "A condition that is reported by status but is not a state. Semantics are in docs/contract.md section 11.",
              "type": "string",
              "enum": [
                "credentials_warning",
                "cleanup_pending",
                "log_unavailable",
                "login_window",
                "user_active"
              ]
            },
            "error_code": {
              "description": "Code carried in structuredContent.code of an isError tool result. JSON-RPC errors use numeric codes instead and never appear here.",
              "type": "string",
              "enum": [
                "gated",
                "paused",
                "disarmed",
                "not_console",
                "locked",
                "display_asleep",
                "permission_missing",
                "permission_stale",
                "secure_input",
                "stale_frame",
                "out_of_frame",
                "user_active",
                "denied_app",
                "denied_shortcut",
                "rate_limited",
                "busy",
                "lease_not_held",
                "lease_held_by_other",
                "lease_expired",
                "invalid_argument",
                "image_too_large",
                "operation_in_progress",
                "operation_id_conflict",
                "operation_capacity",
                "log_unavailable",
                "cleanup_pending",
                "cancelled",
                "interrupted",
                "internal_error"
              ]
            },
            "holder_id": {
              "description": "Lease holder label assigned by the caller: 1 to 128 characters from A-Z a-z 0-9 . _ : -. A label, not a credential. Every handle is scoped to (principal, holder_id).",
              "type": "string",
              "minLength": 1,
              "maxLength": 128,
              "pattern": "^[A-Za-z0-9._:-]+$",
              "not": { "pattern": "[^A-Za-z0-9._:-]" }
            },
            "operation_id": {
              "description": "Caller-supplied idempotency key for one effect call (Crew sends its call ID): 1 to 128 characters from A-Z a-z 0-9 . _ : -. Unique per (principal, holder_id) for the retention window.",
              "type": "string",
              "minLength": 1,
              "maxLength": 128,
              "pattern": "^[A-Za-z0-9._:-]+$",
              "not": { "pattern": "[^A-Za-z0-9._:-]" }
            },
            "frame_id": {
              "description": "Server-minted opaque handle for one screenshot: 1 to 64 characters from A-Z a-z 0-9 _ -. deskhand mints 'frm_' followed by 22 base64url characters; callers treat it as opaque.",
              "type": "string",
              "minLength": 1,
              "maxLength": 64,
              "pattern": "^[A-Za-z0-9_-]+$",
              "not": { "pattern": "[^A-Za-z0-9_-]" }
            },
            "sha256": {
              "description": "Lowercase hexadecimal SHA-256 digest: exactly 64 characters from 0-9 a-f.",
              "type": "string",
              "minLength": 64,
              "maxLength": 64,
              "pattern": "^[0-9a-f]+$",
              "not": { "pattern": "[^0-9a-f]" }
            },
            "timestamp": {
              "description": "UTC RFC 3339 timestamp with a literal Z offset and at most 9 fraction digits. It must be a real UTC instant. The pattern rejects an impossible month, day, hour, minute or second, including a leap second (:60). 29 February of a year that is not a leap year passes the pattern, so a validator must also assert the date-time format; deskhand rejects it either way.",
              "type": "string",
              "format": "date-time",
              "minLength": 20,
              "maxLength": 30,
              "pattern": "^[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)|02-(?:0[1-9]|[12][0-9]))T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\\.[0-9]{1,9})?Z$",
              "not": { "pattern": "[^0-9TZ:.-]" }
            },
            "display_id": {
              "description": "macOS display identifier (CGDirectDisplayID). Valid only within one display_config_generation.",
              "type": "integer",
              "minimum": 0,
              "maximum": 4294967295
            },
            "display_config_generation": {
              "description": "Counter that increases every time the display configuration changes. Strictly increasing within one deskhand process run; compare for equality only.",
              "type": "integer",
              "minimum": 0
            },
            "point": {
              "description": "A point in global points: origin at the top-left corner of the main display, x to the right, y downward. Coordinates may be negative.",
              "type": "object",
              "properties": {
                "x": { "type": "number" },
                "y": { "type": "number" }
              },
              "required": ["x", "y"],
              "additionalProperties": false
            },
            "rect": {
              "description": "A rectangle in global points. The origin may be negative.",
              "type": "object",
              "properties": {
                "x": { "type": "number" },
                "y": { "type": "number" },
                "width": { "type": "number", "minimum": 1 },
                "height": { "type": "number", "minimum": 1 }
              },
              "required": ["x", "y", "width", "height"],
              "additionalProperties": false
            },
            "pixel_size": {
              "description": "A size in whole pixels.",
              "type": "object",
              "properties": {
                "width": { "type": "integer", "minimum": 1 },
                "height": { "type": "integer", "minimum": 1 }
              },
              "required": ["width", "height"],
              "additionalProperties": false
            },
            "frame_coordinate": {
              "description": "One coordinate in the output pixel space of the named frame. Values that fit this range but fall outside the frame are refused with out_of_frame, not invalid_argument.",
              "type": "integer",
              "minimum": -65536,
              "maximum": 65535
            },
            "frame_point": {
              "description": "A pixel in the output pixel space of the named frame: (0, 0) is the top-left pixel.",
              "type": "object",
              "properties": {
                "x": { "$ref": "#/$defs/frame_coordinate" },
                "y": { "$ref": "#/$defs/frame_coordinate" }
              },
              "required": ["x", "y"],
              "additionalProperties": false
            },
            "mouse_button": {
              "type": "string",
              "enum": ["left", "right", "middle"]
            },
            "modifier": {
              "type": "string",
              "enum": ["control", "option", "shift", "command"]
            },
            "modifiers": {
              "description": "Modifier keys held for the whole action. Pressed in the order control, option, shift, command and released in the reverse order, whatever the array order.",
              "type": "array",
              "items": { "$ref": "#/$defs/modifier" },
              "uniqueItems": true,
              "maxItems": 4
            },
            "key": {
              "description": "A key name. A character key names the key that produces that character unshifted in the active keyboard layout.",
              "type": "string",
              "enum": [
                "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
                "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
                "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`",
                "return", "tab", "space", "delete", "forward_delete", "escape",
                "up", "down", "left", "right",
                "home", "end", "page_up", "page_down",
                "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"
              ]
            },
            "bundle_id": {
              "description": "A macOS bundle identifier: 1 to 255 characters from A-Z a-z 0-9 . _ -. Compared exactly, including case.",
              "type": "string",
              "minLength": 1,
              "maxLength": 255,
              "pattern": "^[A-Za-z0-9._-]+$",
              "not": { "pattern": "[^A-Za-z0-9._-]" }
            },
            "permitted_apps": {
              "description": "Optional caller-side narrowing of the per-Mac app policy. When present, every app the app-policy check measures (the frontmost app; for pointer the owner of the topmost window under each checked point; for keyboard the app that owns keyboard focus) must have its bundle identifier in this list as well as being allowed by the Mac's own policy. It can never widen the Mac's policy.",
              "type": "array",
              "items": { "$ref": "#/$defs/bundle_id" },
              "minItems": 1,
              "maxItems": 64,
              "uniqueItems": true
            },
            "app_ref": {
              "description": "An application as measured by deskhand. Its identity for the app policy is the pair (bundle_id, team_id). When deskhand cannot determine the app at all, bundle_id and team_id are null and name is the empty string; the app policy never allows such an app.",
              "type": "object",
              "properties": {
                "bundle_id": {
                  "description": "Null when the process has no bundle identifier or it could not be read. An app with a null bundle_id is never allowed.",
                  "type": ["string", "null"]
                },
                "team_id": {
                  "description": "Code-signing team identifier. Null when the code has none: software signed by Apple as part of macOS, and unsigned or ad-hoc signed code. The app policy tells those cases apart; the wire does not.",
                  "type": ["string", "null"]
                },
                "name": { "type": "string" }
              },
              "required": ["bundle_id", "team_id", "name"]
            },
            "identified_app": {
              "description": "An app_ref whose bundle identifier is known. Every app on a successful effect result is one, because the app policy refuses an app it cannot identify.",
              "allOf": [
                { "$ref": "#/$defs/app_ref" },
                { "properties": { "bundle_id": { "type": "string", "minLength": 1 } } }
              ]
            },
            "measured": {
              "description": "Facts deskhand measured at an app-policy check. On the result of an admitted call other than denied_app: at the last look, the check immediately before the first event (docs/contract.md section 12.3 step 5). On log_unavailable: at the check before admission (section 9.5 step 14). On denied_app: at the check that failed.",
              "type": "object",
              "properties": {
                "frontmost_app": { "$ref": "#/$defs/app_ref" },
                "target_app": {
                  "description": "pointer: the app that owns the topmost window under the first target point. keyboard: the app that owns keyboard focus. On denied_app: the app at the point or focus check that failed. Null only on an error, when the check that failed came before deskhand measured it.",
                  "anyOf": [{ "$ref": "#/$defs/app_ref" }, { "type": "null" }]
                },
                "window_title": {
                  "description": "pointer: title of the topmost window under the first target point. keyboard: title of the focused window of the app that owns keyboard focus. Null when there is no title, on every denied_app, and whenever the app is on the Mac's capture exclusion list. Cut to 512 Unicode scalar values.",
                  "type": ["string", "null"],
                  "maxLength": 512
                },
                "global_point": {
                  "description": "pointer: the global point the first target mapped to; on denied_app, the point whose check failed. keyboard: null.",
                  "anyOf": [{ "$ref": "#/$defs/point" }, { "type": "null" }]
                },
                "drag_end": {
                  "description": "pointer drag only: the same three facts for the last point of path, measured at the same check, before the button goes down. Present whenever measured is present for a drag, except on denied_app, where measured describes only the check that failed. window_title follows the same rules as measured.window_title.",
                  "type": "object",
                  "properties": {
                    "target_app": { "$ref": "#/$defs/app_ref" },
                    "window_title": { "type": ["string", "null"], "maxLength": 512 },
                    "global_point": { "$ref": "#/$defs/point" }
                  },
                  "required": ["target_app", "window_title", "global_point"]
                },
                "measured_at": { "$ref": "#/$defs/timestamp" }
              },
              "required": [
                "frontmost_app",
                "target_app",
                "window_title",
                "global_point",
                "measured_at"
              ],
              "not": {
                "$comment": "No result carries a holder_id (docs/contract.md section 5.4).",
                "required": ["holder_id"]
              }
            },
            "operation_status": {
              "description": "Lifecycle state of an operation record. accepted and executing are transient; the rest are terminal.",
              "type": "string",
              "enum": [
                "accepted",
                "executing",
                "completed",
                "aborted",
                "failed",
                "failed_before_execution",
                "aborted_by_restart"
              ]
            },
            "operation_view": {
              "description": "The operation record as it stood when the response was produced.",
              "type": "object",
              "properties": {
                "status": { "$ref": "#/$defs/operation_status" },
                "events_posted": {
                  "description": "Input events posted for this operation, excluding release events posted by cleanup. A lower bound when status is aborted_by_restart.",
                  "type": "integer",
                  "minimum": 0
                }
              },
              "required": ["status", "events_posted"],
              "not": {
                "$comment": "No result carries a holder_id (docs/contract.md section 5.4).",
                "required": ["holder_id"]
              }
            },
            "stale_frame_reason": {
              "type": "string",
              "description": "Why a frame was refused, in the order the checks run. Diagnostic only: the remedy is always a new screenshot.",
              "enum": [
                "unknown",
                "display_changed",
                "not_latest",
                "too_old",
                "frontmost_changed",
                "pixels_changed"
              ]
            },
            "lease_view": {
              "description": "The lease as seen from the (principal, holder_id) that the call names. It never carries a holder_id: a caller learns whether the holder it named holds the lease, and nothing about any other holder.",
              "type": "object",
              "properties": {
                "held_by_caller": {
                  "description": "True exactly when the named (principal, holder_id) holds the live lease.",
                  "type": "boolean"
                },
                "acquired_at": { "$ref": "#/$defs/timestamp" },
                "expires_at": { "$ref": "#/$defs/timestamp" },
                "expires_in_ms": {
                  "description": "Milliseconds until expires_at by deskhand's clock. Callers schedule renewal from this value, not from expires_at, so clock skew does not matter.",
                  "type": "integer",
                  "minimum": 0
                }
              },
              "required": ["held_by_caller"],
              "not": { "required": ["holder_id"] },
              "if": {
                "properties": { "held_by_caller": { "const": true } },
                "required": ["held_by_caller"]
              },
              "then": { "required": ["acquired_at", "expires_at", "expires_in_ms"] },
              "else": {
                "not": {
                  "anyOf": [
                    { "required": ["acquired_at"] },
                    { "required": ["expires_at"] },
                    { "required": ["expires_in_ms"] }
                  ]
                }
              }
            },
            "effect_result": {
              "description": "structuredContent of a successful pointer or keyboard call.",
              "type": "object",
              "properties": {
                "operation_id": { "$ref": "#/$defs/operation_id" },
                "status": { "const": "completed" },
                "events_posted": { "type": "integer", "minimum": 0 },
                "replayed": {
                  "description": "True when this is the stored result of an earlier call with the same operation_id. Nothing was posted by this call.",
                  "type": "boolean"
                },
                "frame_id": { "$ref": "#/$defs/frame_id" },
                "measured": {
                  "description": "On a success the frontmost app, the target app and the app at the end of a drag are all identified, because the app policy refuses anything else.",
                  "allOf": [
                    { "$ref": "#/$defs/measured" },
                    {
                      "properties": {
                        "frontmost_app": { "$ref": "#/$defs/identified_app" },
                        "target_app": { "$ref": "#/$defs/identified_app" },
                        "drag_end": {
                          "properties": {
                            "target_app": { "$ref": "#/$defs/identified_app" }
                          }
                        }
                      }
                    }
                  ]
                },
                "completed_at": { "$ref": "#/$defs/timestamp" }
              },
              "required": [
                "operation_id",
                "status",
                "events_posted",
                "replayed",
                "frame_id",
                "measured",
                "completed_at"
              ],
              "not": {
                "$comment": "A success has no code, gains no current_state on a replay (docs/contract.md section 12.5), and carries no holder_id (section 5.4).",
                "anyOf": [{ "required": ["code"] }, { "required": ["current_state"] }, { "required": ["holder_id"] }]
              }
            },
            "tool_error": {
              "description": "structuredContent of every isError tool result.",
              "type": "object",
              "properties": {
                "code": { "$ref": "#/$defs/error_code" },
                "message": {
                  "description": "Human-readable explanation. Not stable; never parse it.",
                  "type": "string"
                },
                "state": {
                  "description": "The highest-precedence state at the moment the error was produced. On a replay this is the state stored with the result, not the state now; current_state carries the state now.",
                  "$ref": "#/$defs/state"
                },
                "current_state": {
                  "description": "The highest-precedence state at the moment this response was produced. Present exactly when replayed is true.",
                  "$ref": "#/$defs/state"
                },
                "operation_id": { "$ref": "#/$defs/operation_id" },
                "operation": {
                  "description": "The record for this operation_id, whichever call created it. Present exactly when such a record exists, and on operation_in_progress or operation_id_conflict for a call that is still being admitted (status accepted, events_posted 0). Absent means no input has been posted for this operation_id so far; docs/contract.md section 12.5 says when that is final.",
                  "$ref": "#/$defs/operation_view"
                },
                "replayed": {
                  "description": "Present exactly when this is the result of an admitted call: false when first returned, true when it is the stored result returned to a repeat.",
                  "type": "boolean"
                },
                "retry_after_ms": {
                  "description": "Earliest useful retry, in milliseconds. Required for rate_limited.",
                  "type": "integer",
                  "minimum": 0
                },
                "measured": { "$ref": "#/$defs/measured" },
                "details": {
                  "description": "Code-specific detail. Keys are listed per code in docs/contract.md section 9.2.",
                  "type": "object",
                  "properties": {
                    "reason": { "$ref": "#/$defs/stale_frame_reason" },
                    "argument": {
                      "description": "JSON Pointer (RFC 6901) into arguments naming the offending value.",
                      "type": "string"
                    },
                    "point_index": {
                      "description": "Index into the pointer action's points: 0 for move, click and scroll; an index into path for drag.",
                      "type": "integer",
                      "minimum": 0
                    },
                    "output_pixel_size": { "$ref": "#/$defs/pixel_size" },
                    "image_bytes": { "type": "integer", "minimum": 0 },
                    "max_image_bytes": { "type": "integer", "minimum": 0 },
                    "idle_ms": { "type": "integer", "minimum": 0 },
                    "denied_by": { "enum": ["policy", "permitted_apps"] },
                    "shortcut": { "type": "string" },
                    "expires_in_ms": { "type": "integer", "minimum": 0 }
                  },
                  "not": {
                    "$comment": "No result carries a holder_id, not even the other holder's beside lease_held_by_other.",
                    "required": ["holder_id"]
                  }
                }
              },
              "required": ["code", "message", "state"],
              "not": {
                "$comment": "No result carries a holder_id.",
                "required": ["holder_id"]
              },
              "allOf": [
                {
                  "if": {
                    "properties": { "code": { "const": "stale_frame" } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["details"],
                    "properties": { "details": { "required": ["reason"] } }
                  }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "rate_limited" } },
                    "required": ["code"]
                  },
                  "then": { "required": ["retry_after_ms"] }
                },
                {
                  "if": {
                    "properties": {
                      "code": { "const": "stale_frame" },
                      "details": {
                        "properties": { "reason": { "const": "pixels_changed" } },
                        "required": ["reason"]
                      }
                    },
                    "required": ["code", "details"]
                  },
                  "then": {
                    "properties": { "details": { "required": ["point_index"] } }
                  }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "invalid_argument" } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["details"],
                    "properties": { "details": { "required": ["argument"] } }
                  }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "out_of_frame" } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["details"],
                    "properties": {
                      "details": { "required": ["point_index", "output_pixel_size"] }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "image_too_large" } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["details"],
                    "properties": {
                      "details": { "required": ["image_bytes", "max_image_bytes"] }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "user_active" } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["details"],
                    "properties": { "details": { "required": ["idle_ms"] } }
                  }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "denied_app" } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["details", "measured"],
                    "properties": {
                      "details": { "required": ["denied_by"] },
                      "measured": {
                        "properties": { "window_title": { "const": null } },
                        "not": { "required": ["drag_end"] }
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "log_unavailable" } },
                    "required": ["code"]
                  },
                  "then": { "required": ["measured"] }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "denied_shortcut" } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["details"],
                    "properties": { "details": { "required": ["shortcut"] } }
                  }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "lease_held_by_other" } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["details"],
                    "properties": { "details": { "required": ["expires_in_ms"] } }
                  }
                },
                {
                  "$comment": "Only the codes of contract section 9.2 carry details.",
                  "if": {
                    "properties": {
                      "code": {
                        "enum": [
                          "invalid_argument",
                          "stale_frame",
                          "out_of_frame",
                          "image_too_large",
                          "user_active",
                          "denied_app",
                          "denied_shortcut",
                          "lease_held_by_other"
                        ]
                      }
                    },
                    "required": ["code"]
                  },
                  "else": { "not": { "required": ["details"] } }
                },
                {
                  "$comment": "These four codes always describe an operation that another call started.",
                  "if": {
                    "properties": {
                      "code": {
                        "enum": [
                          "operation_in_progress",
                          "operation_id_conflict",
                          "interrupted",
                          "cancelled"
                        ]
                      }
                    },
                    "required": ["code"]
                  },
                  "then": { "required": ["operation_id", "operation"] }
                },
                {
                  "if": {
                    "properties": { "code": { "enum": ["interrupted", "cancelled"] } },
                    "required": ["code"]
                  },
                  "then": {
                    "required": ["replayed"],
                    "properties": { "replayed": { "const": true } }
                  }
                },
                {
                  "$comment": "A replayed error keeps the state it was stored with and adds the state now.",
                  "if": {
                    "properties": { "replayed": { "const": true } },
                    "required": ["replayed"]
                  },
                  "then": { "required": ["current_state"] },
                  "else": { "not": { "required": ["current_state"] } }
                },
                {
                  "$comment": "When code is the name of a state, state is that state. On a replay state is the stored state, so the rule holds there too.",
                  "if": {
                    "properties": { "code": { "const": "gated" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "gated" } } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "paused" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "paused" } } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "disarmed" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "disarmed" } } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "not_console" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "not_console" } } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "locked" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "locked" } } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "display_asleep" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "display_asleep" } } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "permission_missing" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "permission_missing" } } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "permission_stale" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "permission_stale" } } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "secure_input" } },
                    "required": ["code"]
                  },
                  "then": { "properties": { "state": { "const": "secure_input" } } }
                }
              ]
            }
          }
        }

        """##

    static let displaysInput = #"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/displays.input.json",
          "title": "displays arguments",
          "description": "List the active displays. Takes no arguments.",
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }

        """#

    static let displaysOutput = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/displays.output.json",
          "title": "displays structuredContent",
          "type": "object",
          "oneOf": [
            { "$ref": "#/$defs/displays_result" },
            { "$ref": "#/$defs/displays_error" }
          ],
          "$defs": {
            "displays_error": {
              "description": "A tool_error with one of the codes that displays can return (docs/contract.md section 9.3).",
              "allOf": [
                { "$ref": "../defs.json#/$defs/tool_error" },
                {
                  "properties": {
                    "code": {
                      "enum": [
                        "gated",
                        "paused",
                        "disarmed",
                        "not_console",
                        "locked",
                        "display_asleep",
                        "permission_missing",
                        "permission_stale",
                        "secure_input",
                        "invalid_argument",
                        "internal_error"
                      ]
                    }
                  }
                }
              ]
            },
            "displays_result": {
              "type": "object",
              "properties": {
                "display_config_generation": {
                  "$ref": "../defs.json#/$defs/display_config_generation"
                },
                "displays": {
                  "description": "One entry per active display. In a mirror set only the primary display appears.",
                  "type": "array",
                  "items": { "$ref": "#/$defs/display" }
                }
              },
              "required": ["display_config_generation", "displays"],
              "not": {
                "$comment": "A success has no code, and no result carries a holder_id (docs/contract.md section 5.4).",
                "anyOf": [{ "required": ["code"] }, { "required": ["holder_id"] }]
              }
            },
            "display": {
              "type": "object",
              "properties": {
                "display_id": { "$ref": "../defs.json#/$defs/display_id" },
                "uuid": {
                  "description": "Stable display UUID. Survives reconfiguration, unlike display_id.",
                  "type": "string",
                  "minLength": 36,
                  "maxLength": 36,
                  "pattern": "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
                },
                "name": { "type": "string" },
                "is_main": { "type": "boolean" },
                "is_builtin": { "type": "boolean" },
                "asleep": { "type": "boolean" },
                "bounds": {
                  "description": "The display's bounds in global points.",
                  "$ref": "../defs.json#/$defs/rect"
                },
                "pixel_size": {
                  "description": "The display's size in native pixels.",
                  "$ref": "../defs.json#/$defs/pixel_size"
                },
                "point_pixel_scale": {
                  "description": "Native pixels per point.",
                  "type": "number",
                  "exclusiveMinimum": 0
                }
              },
              "required": [
                "display_id",
                "uuid",
                "name",
                "is_main",
                "is_builtin",
                "asleep",
                "bounds",
                "pixel_size",
                "point_pixel_scale"
              ]
            }
          }
        }

        """##

    static let keyboardInput = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/keyboard.input.json",
          "title": "keyboard arguments",
          "description": "Type text, or press one key with optional modifiers.",
          "type": "object",
          "properties": {
            "holder_id": { "$ref": "../defs.json#/$defs/holder_id" },
            "frame_id": { "$ref": "../defs.json#/$defs/frame_id" },
            "operation_id": { "$ref": "../defs.json#/$defs/operation_id" },
            "permitted_apps": { "$ref": "../defs.json#/$defs/permitted_apps" },
            "action": {
              "anyOf": [
                { "$ref": "#/$defs/keyboard_type" },
                { "$ref": "#/$defs/keyboard_press" }
              ]
            }
          },
          "required": ["holder_id", "frame_id", "operation_id", "action"],
          "additionalProperties": false,
          "$defs": {
            "keyboard_type": {
              "description": "Type text as Unicode input, independent of the keyboard layout. Control characters, including newline and tab, are refused: send them as press actions.",
              "type": "object",
              "properties": {
                "type": { "const": "type" },
                "text": {
                  "description": "1 to 1024 Unicode code points with no C0 or C1 control character, DEL, U+2028 or U+2029.",
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 1024,
                  "not": {
                    "pattern": "[\\u0000-\\u001F\\u007F-\\u009F\\u2028\\u2029]"
                  }
                }
              },
              "required": ["type", "text"],
              "additionalProperties": false
            },
            "keyboard_press": {
              "description": "Press the modifiers, press the key, hold for hold_ms, release the key, release the modifiers. A key with modifiers is a chord.",
              "type": "object",
              "properties": {
                "type": { "const": "press" },
                "key": { "$ref": "../defs.json#/$defs/key" },
                "modifiers": {
                  "$ref": "../defs.json#/$defs/modifiers",
                  "default": []
                },
                "hold_ms": {
                  "description": "How long the key stays down. Key repeat is not synthesized.",
                  "type": "integer",
                  "minimum": 0,
                  "maximum": 5000,
                  "default": 0
                }
              },
              "required": ["type", "key"],
              "additionalProperties": false
            }
          }
        }

        """##

    static let keyboardOutput = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/keyboard.output.json",
          "title": "keyboard structuredContent",
          "type": "object",
          "oneOf": [
            { "$ref": "#/$defs/keyboard_result" },
            { "$ref": "#/$defs/keyboard_error" }
          ],
          "$defs": {
            "keyboard_result": {
              "description": "A keyboard call has no target point: global_point is null and there is no drag_end.",
              "allOf": [
                { "$ref": "../defs.json#/$defs/effect_result" },
                {
                  "properties": {
                    "measured": {
                      "properties": { "global_point": { "type": "null" } },
                      "not": { "required": ["drag_end"] }
                    }
                  }
                }
              ]
            },
            "keyboard_error": {
              "description": "A tool_error with one of the codes that keyboard can return (docs/contract.md section 9.3).",
              "allOf": [
                { "$ref": "../defs.json#/$defs/tool_error" },
                {
                  "properties": {
                    "code": {
                      "enum": [
                        "gated",
                        "paused",
                        "disarmed",
                        "not_console",
                        "locked",
                        "display_asleep",
                        "permission_missing",
                        "permission_stale",
                        "secure_input",
                        "denied_shortcut",
                        "stale_frame",
                        "user_active",
                        "denied_app",
                        "rate_limited",
                        "busy",
                        "lease_not_held",
                        "lease_held_by_other",
                        "lease_expired",
                        "invalid_argument",
                        "operation_in_progress",
                        "operation_id_conflict",
                        "operation_capacity",
                        "log_unavailable",
                        "cleanup_pending",
                        "cancelled",
                        "interrupted",
                        "internal_error"
                      ]
                    }
                  }
                }
              ]
            }
          }
        }

        """##

    static let leaseInput = #"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/lease.input.json",
          "title": "lease arguments",
          "description": "Acquire, renew or release the lease that lets one holder drive this Mac. It changes who may post input, so a caller classifies it as an effect.",
          "type": "object",
          "properties": {
            "op": {
              "type": "string",
              "enum": ["acquire", "renew", "release"]
            },
            "holder_id": { "$ref": "../defs.json#/$defs/holder_id" },
            "ttl_ms": {
              "description": "Requested lease lifetime from now, for acquire and renew. It must be absent on release: deskhand refuses a release that carries it with invalid_argument. Input schemas stay flat, so this schema cannot state that rule.",
              "type": "integer",
              "minimum": 5000,
              "maximum": 120000,
              "default": 30000
            }
          },
          "required": ["op", "holder_id"],
          "additionalProperties": false
        }

        """#

    static let leaseOutput = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/lease.output.json",
          "title": "lease structuredContent",
          "type": "object",
          "oneOf": [
            { "$ref": "#/$defs/lease_tool_result" },
            { "$ref": "#/$defs/lease_error" }
          ],
          "$defs": {
            "lease_tool_result": {
              "description": "The outcome of the lease operation and the lease as the named holder now sees it. A refused operation is reported here, in lease_result, and is not a tool error.",
              "type": "object",
              "properties": {
                "lease_result": { "$ref": "#/$defs/lease_result" },
                "lease": { "$ref": "../defs.json#/$defs/lease_view" }
              },
              "required": ["lease_result", "lease"],
              "not": {
                "$comment": "No result carries a holder_id.",
                "anyOf": [{ "required": ["code"] }, { "required": ["holder_id"] }]
              },
              "if": {
                "properties": {
                  "lease_result": {
                    "properties": { "outcome": { "enum": ["acquired", "renewed"] } },
                    "required": ["outcome"]
                  }
                },
                "required": ["lease_result"]
              },
              "then": {
                "properties": {
                  "lease": { "properties": { "held_by_caller": { "const": true } } }
                }
              },
              "else": {
                "properties": {
                  "lease": { "properties": { "held_by_caller": { "const": false } } }
                }
              }
            },
            "lease_result": {
              "type": "object",
              "properties": {
                "op": { "type": "string", "enum": ["acquire", "renew", "release"] },
                "outcome": {
                  "type": "string",
                  "enum": ["acquired", "renewed", "released", "not_held", "refused"]
                },
                "code": {
                  "description": "Why the operation was refused. Present exactly when outcome is refused.",
                  "type": "string",
                  "enum": [
                    "gated",
                    "paused",
                    "disarmed",
                    "lease_not_held",
                    "lease_held_by_other",
                    "lease_expired"
                  ]
                },
                "expires_in_ms": {
                  "description": "Present exactly when code is lease_held_by_other: milliseconds until the other holder's lease runs out if it is not renewed.",
                  "type": "integer",
                  "minimum": 0
                }
              },
              "required": ["op", "outcome"],
              "not": {
                "$comment": "No result carries a holder_id, not even the other holder's beside lease_held_by_other.",
                "required": ["holder_id"]
              },
              "allOf": [
                {
                  "if": {
                    "properties": { "outcome": { "const": "refused" } },
                    "required": ["outcome"]
                  },
                  "then": { "required": ["code"] },
                  "else": { "not": { "required": ["code"] } }
                },
                {
                  "if": {
                    "properties": { "code": { "const": "lease_held_by_other" } },
                    "required": ["code"]
                  },
                  "then": { "required": ["expires_in_ms"] },
                  "else": { "not": { "required": ["expires_in_ms"] } }
                },
                {
                  "if": {
                    "properties": { "op": { "const": "acquire" } },
                    "required": ["op"]
                  },
                  "then": {
                    "properties": {
                      "outcome": { "enum": ["acquired", "renewed", "refused"] },
                      "code": {
                        "enum": ["gated", "paused", "disarmed", "lease_held_by_other"]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "op": { "const": "renew" } },
                    "required": ["op"]
                  },
                  "then": {
                    "properties": { "outcome": { "enum": ["renewed", "refused"] } }
                  }
                },
                {
                  "if": {
                    "properties": { "op": { "const": "release" } },
                    "required": ["op"]
                  },
                  "then": {
                    "properties": {
                      "outcome": { "enum": ["released", "not_held", "refused"] },
                      "code": { "enum": ["lease_held_by_other"] }
                    }
                  }
                }
              ]
            },
            "lease_error": {
              "description": "A tool_error with one of the codes that lease can return (docs/contract.md section 9.3).",
              "allOf": [
                { "$ref": "../defs.json#/$defs/tool_error" },
                {
                  "properties": {
                    "code": {
                      "enum": [
                        "invalid_argument",
                        "internal_error"
                      ]
                    }
                  }
                }
              ]
            }
          }
        }

        """##

    static let pointerInput = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/pointer.input.json",
          "title": "pointer arguments",
          "description": "Move, click, drag or scroll at positions given in the output pixel space of the named frame.",
          "type": "object",
          "properties": {
            "holder_id": { "$ref": "../defs.json#/$defs/holder_id" },
            "frame_id": { "$ref": "../defs.json#/$defs/frame_id" },
            "operation_id": { "$ref": "../defs.json#/$defs/operation_id" },
            "permitted_apps": { "$ref": "../defs.json#/$defs/permitted_apps" },
            "action": {
              "anyOf": [
                { "$ref": "#/$defs/pointer_move" },
                { "$ref": "#/$defs/pointer_click" },
                { "$ref": "#/$defs/pointer_drag" },
                { "$ref": "#/$defs/pointer_scroll" }
              ]
            }
          },
          "required": ["holder_id", "frame_id", "operation_id", "action"],
          "additionalProperties": false,
          "$defs": {
            "pointer_move": {
              "description": "Move the pointer to a point. Nothing is pressed.",
              "type": "object",
              "properties": {
                "type": { "const": "move" },
                "x": { "$ref": "../defs.json#/$defs/frame_coordinate" },
                "y": { "$ref": "../defs.json#/$defs/frame_coordinate" }
              },
              "required": ["type", "x", "y"],
              "additionalProperties": false
            },
            "pointer_click": {
              "description": "Move to a point, then press and release a button count times. Modifiers are held around all the clicks.",
              "type": "object",
              "properties": {
                "type": { "const": "click" },
                "x": { "$ref": "../defs.json#/$defs/frame_coordinate" },
                "y": { "$ref": "../defs.json#/$defs/frame_coordinate" },
                "button": {
                  "$ref": "../defs.json#/$defs/mouse_button",
                  "default": "left"
                },
                "count": {
                  "description": "1 is a click, 2 a double-click, 3 a triple-click.",
                  "type": "integer",
                  "minimum": 1,
                  "maximum": 3,
                  "default": 1
                },
                "modifiers": {
                  "$ref": "../defs.json#/$defs/modifiers",
                  "default": []
                }
              },
              "required": ["type", "x", "y"],
              "additionalProperties": false
            },
            "pointer_drag": {
              "description": "Press the button at the first point, move through each later point in order, release at the last. A path of two identical points is a press-and-hold of duration_ms. duration_ms is a minimum for any other path.",
              "type": "object",
              "properties": {
                "type": { "const": "drag" },
                "path": {
                  "type": "array",
                  "items": { "$ref": "../defs.json#/$defs/frame_point" },
                  "minItems": 2,
                  "maxItems": 32
                },
                "button": {
                  "$ref": "../defs.json#/$defs/mouse_button",
                  "default": "left"
                },
                "modifiers": {
                  "$ref": "../defs.json#/$defs/modifiers",
                  "default": []
                },
                "duration_ms": {
                  "description": "The least time from button down to button up, spread evenly along the path. A long path takes longer, because the pointer moves at most 8 frame pixels per event and each move is checked first.",
                  "type": "integer",
                  "minimum": 50,
                  "maximum": 5000,
                  "default": 500
                }
              },
              "required": ["type", "path"],
              "additionalProperties": false
            },
            "pointer_scroll": {
              "description": "Move to a point, then scroll. Positive dy reveals content further down; positive dx reveals content further right. Deltas are in output pixels of the frame. At least one of dx and dy must be present and non-zero.",
              "type": "object",
              "properties": {
                "type": { "const": "scroll" },
                "x": { "$ref": "../defs.json#/$defs/frame_coordinate" },
                "y": { "$ref": "../defs.json#/$defs/frame_coordinate" },
                "dx": {
                  "type": "integer",
                  "minimum": -10000,
                  "maximum": 10000,
                  "default": 0
                },
                "dy": {
                  "type": "integer",
                  "minimum": -10000,
                  "maximum": 10000,
                  "default": 0
                },
                "modifiers": {
                  "$ref": "../defs.json#/$defs/modifiers",
                  "default": []
                }
              },
              "required": ["type", "x", "y"],
              "anyOf": [
                {
                  "required": ["dx"],
                  "properties": { "dx": { "not": { "const": 0 } } }
                },
                {
                  "required": ["dy"],
                  "properties": { "dy": { "not": { "const": 0 } } }
                }
              ],
              "additionalProperties": false
            }
          }
        }

        """##

    static let pointerOutput = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/pointer.output.json",
          "title": "pointer structuredContent",
          "type": "object",
          "oneOf": [
            { "$ref": "#/$defs/pointer_result" },
            { "$ref": "#/$defs/pointer_error" }
          ],
          "$defs": {
            "pointer_result": {
              "description": "A successful pointer call always measured a window under its target, so global_point is never null.",
              "allOf": [
                { "$ref": "../defs.json#/$defs/effect_result" },
                {
                  "properties": {
                    "measured": {
                      "properties": {
                        "global_point": { "$ref": "../defs.json#/$defs/point" }
                      }
                    }
                  }
                }
              ]
            },
            "pointer_error": {
              "description": "A tool_error with one of the codes that pointer can return (docs/contract.md section 9.3).",
              "allOf": [
                { "$ref": "../defs.json#/$defs/tool_error" },
                {
                  "properties": {
                    "code": {
                      "enum": [
                        "gated",
                        "paused",
                        "disarmed",
                        "not_console",
                        "locked",
                        "display_asleep",
                        "permission_missing",
                        "permission_stale",
                        "secure_input",
                        "out_of_frame",
                        "stale_frame",
                        "user_active",
                        "denied_app",
                        "rate_limited",
                        "busy",
                        "lease_not_held",
                        "lease_held_by_other",
                        "lease_expired",
                        "invalid_argument",
                        "operation_in_progress",
                        "operation_id_conflict",
                        "operation_capacity",
                        "log_unavailable",
                        "cleanup_pending",
                        "cancelled",
                        "interrupted",
                        "internal_error"
                      ]
                    }
                  }
                }
              ]
            }
          }
        }

        """##

    static let screenshotInput = #"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/screenshot.input.json",
          "title": "screenshot arguments",
          "description": "Capture one display, or a region of it, and mint a frame.",
          "type": "object",
          "properties": {
            "holder_id": {
              "description": "The frame is scoped to this holder. Holding the lease is not required to take a screenshot.",
              "$ref": "../defs.json#/$defs/holder_id"
            },
            "display_id": {
              "description": "The display to capture. Defaults to the main display.",
              "$ref": "../defs.json#/$defs/display_id"
            },
            "region": {
              "description": "Region to capture, in global points. Must lie entirely inside the display's bounds. Defaults to the whole display.",
              "$ref": "../defs.json#/$defs/rect"
            },
            "format": {
              "type": "string",
              "enum": ["jpeg", "png"],
              "default": "jpeg"
            },
            "max_long_edge": {
              "description": "Upper bound on the longer output edge, in pixels.",
              "type": "integer",
              "minimum": 256,
              "maximum": 2576,
              "default": 2576
            }
          },
          "required": ["holder_id"],
          "additionalProperties": false
        }

        """#

    static let screenshotOutput = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/screenshot.output.json",
          "title": "screenshot structuredContent",
          "description": "Frame metadata. The image itself is the image content block of the same result.",
          "type": "object",
          "oneOf": [
            { "$ref": "#/$defs/screenshot_result" },
            { "$ref": "#/$defs/screenshot_error" }
          ],
          "$defs": {
            "screenshot_error": {
              "description": "A tool_error with one of the codes that screenshot can return (docs/contract.md section 9.3).",
              "allOf": [
                { "$ref": "../defs.json#/$defs/tool_error" },
                {
                  "properties": {
                    "code": {
                      "enum": [
                        "gated",
                        "paused",
                        "disarmed",
                        "not_console",
                        "locked",
                        "display_asleep",
                        "permission_missing",
                        "permission_stale",
                        "secure_input",
                        "invalid_argument",
                        "image_too_large",
                        "internal_error"
                      ]
                    }
                  }
                }
              ]
            },
            "screenshot_result": {
              "type": "object",
              "properties": {
                "frame_id": { "$ref": "../defs.json#/$defs/frame_id" },
                "sha256": {
                  "description": "SHA-256 of the encoded image bytes, that is, of the image content block's data after base64 decoding.",
                  "$ref": "../defs.json#/$defs/sha256"
                },
                "display_id": { "$ref": "../defs.json#/$defs/display_id" },
                "display_config_generation": {
                  "$ref": "../defs.json#/$defs/display_config_generation"
                },
                "capture_rect": {
                  "description": "The rectangle actually captured, in global points.",
                  "$ref": "../defs.json#/$defs/rect"
                },
                "source_pixel_size": {
                  "description": "Size of capture_rect in native pixels.",
                  "$ref": "../defs.json#/$defs/pixel_size"
                },
                "output_pixel_size": {
                  "description": "Size of the returned image. Pointer targets are expressed in this pixel space. Neither edge is over 2576, and width times height is at most 3,588,000, which a schema cannot state.",
                  "$ref": "../defs.json#/$defs/pixel_size",
                  "properties": {
                    "width": { "maximum": 2576 },
                    "height": { "maximum": 2576 }
                  }
                },
                "point_pixel_scale": {
                  "description": "Native pixels per point for this display.",
                  "type": "number",
                  "exclusiveMinimum": 0
                },
                "downscale": {
                  "description": "The scale applied to the source pixels, in (0, 1]. 1 means not downscaled.",
                  "type": "number",
                  "exclusiveMinimum": 0,
                  "maximum": 1
                },
                "format": { "type": "string", "enum": ["jpeg", "png"] },
                "mime_type": {
                  "type": "string",
                  "enum": ["image/jpeg", "image/png"]
                },
                "jpeg_quality": {
                  "description": "The JPEG quality used. Present exactly when format is jpeg.",
                  "enum": [85, 75, 65, 60]
                },
                "image_bytes": {
                  "description": "Size of the encoded image before base64. At most 3,750,000, so the base64 text is at most 5,000,000 characters.",
                  "type": "integer",
                  "minimum": 1,
                  "maximum": 3750000
                },
                "captured_at": { "$ref": "../defs.json#/$defs/timestamp" },
                "max_age_ms": {
                  "description": "The frame is refused as too_old once this many milliseconds have passed since captured_at.",
                  "type": "integer",
                  "minimum": 5000,
                  "maximum": 600000
                },
                "pointer_position": {
                  "description": "Where the pointer was at capture, in output pixels, or null when it was outside capture_rect. The pointer is never drawn into the image.",
                  "anyOf": [
                    { "$ref": "../defs.json#/$defs/frame_point" },
                    { "type": "null" }
                  ]
                },
                "frontmost_app": {
                  "description": "The frontmost app at capture. When deskhand could not determine one: bundle_id and team_id null and name empty.",
                  "$ref": "../defs.json#/$defs/app_ref"
                }
              },
              "required": [
                "frame_id",
                "sha256",
                "display_id",
                "display_config_generation",
                "capture_rect",
                "source_pixel_size",
                "output_pixel_size",
                "point_pixel_scale",
                "downscale",
                "format",
                "mime_type",
                "image_bytes",
                "captured_at",
                "max_age_ms",
                "pointer_position",
                "frontmost_app"
              ],
              "not": {
                "$comment": "A success has no code, and no result carries a holder_id (docs/contract.md section 5.4).",
                "anyOf": [{ "required": ["code"] }, { "required": ["holder_id"] }]
              },
              "if": {
                "properties": { "format": { "const": "jpeg" } },
                "required": ["format"]
              },
              "then": {
                "required": ["jpeg_quality"],
                "properties": { "mime_type": { "const": "image/jpeg" } }
              },
              "else": {
                "not": { "required": ["jpeg_quality"] },
                "properties": { "mime_type": { "const": "image/png" } }
              }
            }
          }
        }

        """##

    static let statusInput = #"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/status.input.json",
          "title": "status arguments",
          "description": "Report deskhand's state. A pure read: it changes nothing and never posts input. Optionally report whether a named holder holds the lease, and look up one operation record.",
          "type": "object",
          "properties": {
            "holder_id": {
              "description": "Report the lease as seen from this holder. Without it the result's lease is null.",
              "$ref": "../defs.json#/$defs/holder_id"
            },
            "operation": {
              "description": "Look up the record of one effect call. Nothing is executed and nothing is posted. The result's operation member is the record, or null when there is none.",
              "type": "object",
              "properties": {
                "holder_id": { "$ref": "../defs.json#/$defs/holder_id" },
                "operation_id": { "$ref": "../defs.json#/$defs/operation_id" }
              },
              "required": ["holder_id", "operation_id"],
              "additionalProperties": false
            }
          },
          "additionalProperties": false
        }

        """#

    static let statusOutput = ##"""
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$id": "https://deskhand.invalid/schemas/tools/status.output.json",
          "title": "status structuredContent",
          "type": "object",
          "oneOf": [
            { "$ref": "#/$defs/status_result" },
            { "$ref": "#/$defs/status_error" }
          ],
          "$defs": {
            "status_result": {
              "type": "object",
              "properties": {
                "contract_version": {
                  "description": "Version of docs/contract.md this build implements. These schemas describe 0.11-draft.",
                  "const": "0.11-draft"
                },
                "mcp_protocol_version": { "const": "2026-07-28" },
                "server_version": { "type": "string" },
                "mac": {
                  "description": "This Mac's configured name, for example lunus-macbook-pro.",
                  "type": "string"
                },
                "time": { "$ref": "../defs.json#/$defs/timestamp" },
                "started_at": {
                  "description": "When this deskhand process started. A change means every frame and the lease were dropped.",
                  "$ref": "../defs.json#/$defs/timestamp"
                },
                "state": { "$ref": "../defs.json#/$defs/state" },
                "active_states": {
                  "description": "Every state other than ok whose condition holds now, in precedence order. Empty exactly when state is ok; otherwise its first item equals state.",
                  "type": "array",
                  "items": { "$ref": "../defs.json#/$defs/blocking_state" },
                  "uniqueItems": true
                },
                "conditions": {
                  "type": "array",
                  "items": { "$ref": "../defs.json#/$defs/condition" },
                  "uniqueItems": true
                },
                "armed_until": {
                  "description": "When arming expires, or null when not armed.",
                  "anyOf": [
                    { "$ref": "../defs.json#/$defs/timestamp" },
                    { "type": "null" }
                  ]
                },
                "lease": {
                  "description": "The lease as seen from the holder_id the call named. Null exactly when the call named no holder_id.",
                  "anyOf": [
                    { "$ref": "../defs.json#/$defs/lease_view" },
                    { "type": "null" }
                  ]
                },
                "operation": {
                  "description": "Present exactly when the call had an operation argument: the record for that (principal, holder_id, operation_id), or null when there is none.",
                  "anyOf": [
                    { "$ref": "../defs.json#/$defs/operation_view" },
                    { "type": "null" }
                  ]
                },
                "display_config_generation": {
                  "$ref": "../defs.json#/$defs/display_config_generation"
                },
                "limits": { "$ref": "#/$defs/limits" }
              },
              "required": [
                "contract_version",
                "mcp_protocol_version",
                "server_version",
                "mac",
                "time",
                "started_at",
                "state",
                "active_states",
                "conditions",
                "armed_until",
                "lease",
                "display_config_generation",
                "limits"
              ],
              "not": {
                "$comment": "status no longer performs lease operations (amendment 4), so it never carries lease_result. No result carries a holder_id.",
                "anyOf": [
                  { "required": ["code"] },
                  { "required": ["lease_result"] },
                  { "required": ["holder_id"] }
                ]
              },
              "allOf": [
                {
                  "if": {
                    "properties": { "state": { "const": "ok" } },
                    "required": ["state"]
                  },
                  "then": { "properties": { "active_states": { "maxItems": 0 } } }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "gated" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "gated" }]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "paused" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "paused" }]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "disarmed" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "disarmed" }]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "not_console" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "not_console" }]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "locked" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "locked" }]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "display_asleep" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "display_asleep" }]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "permission_missing" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "permission_missing" }]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "permission_stale" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "permission_stale" }]
                      }
                    }
                  }
                },
                {
                  "if": {
                    "properties": { "state": { "const": "secure_input" } },
                    "required": ["state"]
                  },
                  "then": {
                    "properties": {
                      "active_states": {
                        "minItems": 1,
                        "prefixItems": [{ "const": "secure_input" }]
                      }
                    }
                  }
                }
              ]
            },
            "status_error": {
              "description": "A tool_error with one of the codes that status can return (docs/contract.md section 9.3).",
              "allOf": [
                { "$ref": "../defs.json#/$defs/tool_error" },
                {
                  "properties": {
                    "code": {
                      "enum": [
                        "invalid_argument",
                        "internal_error"
                      ]
                    }
                  }
                }
              ]
            },
            "limits": {
              "description": "The limits in force on this Mac. Contract constants are repeated so a caller can check them; configured values are authoritative here.",
              "type": "object",
              "properties": {
                "max_long_edge": { "const": 2576 },
                "min_long_edge": { "const": 256 },
                "max_pixels": { "const": 3588000 },
                "max_image_bytes": {
                  "description": "Largest encoded image in bytes, before base64.",
                  "const": 3750000
                },
                "frame_max_age_ms": {
                  "type": "integer",
                  "minimum": 5000,
                  "maximum": 600000
                },
                "user_activity_lookback_ms": { "const": 3000 },
                "actions_per_minute": { "type": "integer", "minimum": 1 },
                "lease_ttl_min_ms": { "const": 5000 },
                "lease_ttl_max_ms": { "const": 120000 },
                "keyboard_max_text_length": { "const": 1024 },
                "operation_retention_ms": {
                  "description": "How long an operation record is kept. A caller must not repeat an operation_id after this.",
                  "type": "integer",
                  "minimum": 1
                },
                "operation_max_records": {
                  "description": "Most operation records kept per principal inside the retention window.",
                  "type": "integer",
                  "minimum": 1
                }
              },
              "required": [
                "operation_retention_ms",
                "operation_max_records",
                "max_long_edge",
                "min_long_edge",
                "max_pixels",
                "max_image_bytes",
                "frame_max_age_ms",
                "user_activity_lookback_ms",
                "actions_per_minute",
                "lease_ttl_min_ms",
                "lease_ttl_max_ms",
                "keyboard_max_text_length"
              ]
            }
          }
        }

        """##
}
