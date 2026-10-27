#!/usr/bin/env bash
# PreToolUse hook on Claude's Agent tool (bootstrap.sh installs it as ~/.claude/hooks/femme-subagent-model.sh).
# Subagents on this box run on Opus or Sonnet, never Fable. A requested Fable becomes Opus; the built-in
# Plan agent, which inherits the session's model, gets Opus; a fork can only run on the session's model,
# so from a Fable session it is refused with the fix in the reason. Agents that name no model get
# CLAUDE_CODE_SUBAGENT_MODEL=opus from settings.json, which bootstrap.sh sets.
set -u
in=$(cat)
eval "$(jq -r '@sh "model=\(.tool_input.model // "") type=\(.tool_input.subagent_type // "") tp=\(.transcript_path // "")"' <<<"$in")"
if [ "$type" = fork ]; then  # the session's model: the last assistant message in the transcript
  case $(grep -o '"model":"claude-[^"]*"' "$tp" 2>/dev/null | tail -n1) in *fable*)
    jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason:
      "This session runs on Fable and a fork always runs on the session'\''s model; subagents here run on Opus or Sonnet. Spawn a general-purpose agent with model \"opus\" instead and brief it fully: it starts without this conversation'\''s context."}}'
    exit 0 ;;
  esac
fi
case $model in *fable*) new=opus ;; "") [ "$type" = Plan ] && new=opus ;; esac
[ -z "${new:-}" ] || jq --arg m "$new" '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: (.tool_input + {model: $m})}}' <<<"$in"
exit 0
