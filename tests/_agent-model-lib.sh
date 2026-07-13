#!/usr/bin/env bash
# _agent-model-lib.sh — single definition point for agent-model literals used
# across the e2e test suite (rip-cage-eb4h).
#
# WHY: a retired hardcoded openrouter model (anthropic/claude-3.5-haiku, live
# 404) silently broke multiple container tests because the literal was
# scattered across 3 files (rip-cage-7atw). Centralizing here makes the next
# model retirement a one-line fix instead of a scattered re-rot.
#
# Usage: source this file from any test that drives a real pi agent, then use
# ${RC_TEST_AGENT_MODEL} / ${RC_TEST_AGENT_MODEL_NATIVE} in place of a literal
# model id. Both vars support env-override (e.g. to pin a different model for
# a one-off run without editing this file).
#
# Must NOT execute any checks at source-time (definitions only).

# RC_TEST_AGENT_MODEL — openrouter-form model id, used with
# `pi --provider openrouter --model <id>`.
: "${RC_TEST_AGENT_MODEL:=anthropic/claude-haiku-4.5}"
export RC_TEST_AGENT_MODEL

# RC_TEST_AGENT_MODEL_NATIVE — claude-CLI-form model id, used with
# `--model <id>` against the native claude CLI / am agents register.
: "${RC_TEST_AGENT_MODEL_NATIVE:=claude-sonnet}"
export RC_TEST_AGENT_MODEL_NATIVE
