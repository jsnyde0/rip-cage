/**
 * dcg-gate.ts — Rip Cage pi-cage DCG guard (rip-cage-bl1; compound-blocker removed rip-cage-4r8)
 *
 * Brings pi cages to DCG parity with Claude Code cages.
 * Fires for EVERY pi tool call (not just "bash"), closing the multi-tool bypass
 * that a name-"bash"-only override would leave open.
 *
 * Single-gate design (compound-blocker removed in rip-cage-4r8 — DCG is chaining-robust):
 *   1. DCG destructive-command guard — delegated to dcg-guard wrapper
 *      (/usr/local/lib/rip-cage/bin/dcg-guard, ADR-025 D3+D4 FIRM).
 *      The envelope always uses tool_name="bash" (a value in dcg's
 *      is_supported_shell_tool allowlist) regardless of the originating
 *      pi tool name — otherwise dcg's tool_name filter returns no-command
 *      and silently FAILS OPEN for MCP/custom exec tools.
 *      Decision is read from dcg stdout JSON hookSpecificOutput.permissionDecision,
 *      NOT the exit code.
 *      DCG rules are unanchored whole-command regexes, so chaining (&&, ;, ||)
 *      does NOT bypass them — verified live 2026-06-03 (rip-cage-4r8).
 *
 * On deny → { block: true, reason } (agent receives readable refusal).
 * On guard internal error → fail OPEN (undefined); logs to stderr — never wedge the agent.
 *
 * ADR refs: ADR-024 D2 (on-device-harm symmetry), ADR-019 D4 (goal-FIRM),
 *           ADR-025 D3/D4 (dcg-guard wrapper, FIRM), ADR-001 (fail-loud),
 *           ADR-002 D5 (compound-blocker removal rationale).
 */

import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// Path to the cage-owned, root-owned (agent-unwritable) DCG guard wrapper.
// Baked into the image; the agent cannot modify or delete it.
const DCG_GUARD = "/usr/local/lib/rip-cage/bin/dcg-guard";

/**
 * Extract a command string from a tool input, if present.
 *
 * Field coverage rationale (F3, rip-cage-bl1 repair):
 *   - "command": pi's built-in bash tool (bash.ts:34 bashSchema) AND all known exec-capable
 *     extension tools (ssh.ts, sandbox.ts) replace/override the built-in bash tool and use the
 *     same BashToolInput schema — field "command" covers all real exec-capable tools in the
 *     current pi install (PI_VERSION=latest, ADR-019 D8).
 *   - pi has no MCP server bridge (no MCP packages found in pi-mono); CustomToolCallEvent
 *     (types.ts:799) carries input: Record<string, unknown> for any extension-registered tool.
 *
 * Known acceptable gap: a custom extension that registers a NEW exec-capable tool (not
 * replacing "bash") with a different field name (e.g. "script", "cmd") would pass through
 * unguarded here. This gap is bounded by the guard-parity re-verify check in
 * tests/test-pi-dcg-gate.sh (section 5, rip-cage-9yg0), which fires FAIL in rc test when
 * a non-"command" exec field appears in the installed pi dist — catching drift before it
 * reaches a running cage. The live-fire proof (F2) uses the non-bash tool name path
 * to verify the tool_name="bash" pinning guards it.
 *
 * Returns undefined if the input has no "command" field or it is not a non-empty string.
 */
function extractCommand(input: Record<string, unknown>): string | undefined {
	const cmd = input?.command;
	if (typeof cmd === "string" && cmd.length > 0) {
		return cmd;
	}
	return undefined;
}

/**
 * Call dcg-guard with the command.
 * ALWAYS uses tool_name="bash" in the envelope — dcg's is_supported_shell_tool allowlist
 * accepts: "bash" | "launch-process" | "run_shell_command" | "run-shell-command" (case-insensitive).
 * We pin to "bash" (lowercase) so the guard evaluates any exec-capable tool regardless of
 * the originating pi tool's native name.
 *
 * Returns { decision: "deny", reason } | { decision: "allow" } | { decision: "error", message }
 */
function callDcgGuard(command: string): { decision: "deny"; reason: string } | { decision: "allow" } | { decision: "error"; message: string } {
	const envelope = JSON.stringify({
		tool_name: "bash",
		tool_input: { command },
	});

	let result: ReturnType<typeof spawnSync>;
	try {
		result = spawnSync(DCG_GUARD, [], {
			input: envelope,
			encoding: "utf8",
			timeout: 5000,
		});
	} catch (err) {
		return { decision: "error", message: `dcg-guard spawn failed: ${err instanceof Error ? err.message : String(err)}` };
	}

	if (result.error) {
		return { decision: "error", message: `dcg-guard error: ${result.error.message}` };
	}

	const stdout = result.stdout ?? "";
	if (!stdout.trim()) {
		// No output → allow (dcg found no issue or didn't evaluate the command)
		return { decision: "allow" };
	}

	let parsed: Record<string, unknown>;
	try {
		parsed = JSON.parse(stdout);
	} catch {
		// Non-JSON output → treat as allow (unexpected output, but don't wedge agent)
		return { decision: "allow" };
	}

	const hookOutput = parsed?.hookSpecificOutput as Record<string, unknown> | undefined;
	const permissionDecision = hookOutput?.permissionDecision;

	if (permissionDecision === "deny") {
		const reason = (hookOutput?.permissionDecisionReason as string | undefined)
			?? (parsed?.reason as string | undefined)
			?? "Command blocked by DCG destructive-command guard";
		return { decision: "deny", reason };
	}

	return { decision: "allow" };
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		const ev = event as { toolName: string; input: Record<string, unknown> };

		// Extract command from input — works for "bash" and any custom/MCP exec tool
		const command = extractCommand(ev.input);
		if (!command) {
			// Not an exec-capable call (no "command" field) → pass through
			return undefined;
		}

		// DCG destructive-command guard
		// CRITICAL: always pass tool_name="bash" to dcg regardless of ev.toolName —
		// otherwise dcg's is_supported_shell_tool filter returns no-command and silently
		// FAILS OPEN for MCP/custom tool names not in dcg's allowlist.
		// DCG uses unanchored whole-command regexes — chaining (&&, ;, ||) does NOT bypass
		// it; a compound-blocker is therefore not needed here (rip-cage-4r8 / ADR-002 D5).
		const dcgResult = callDcgGuard(command);
		if (dcgResult.decision === "deny") {
			return { block: true, reason: dcgResult.reason };
		}
		if (dcgResult.decision === "error") {
			// Fail open: log but don't block the agent
			console.error(`[rip-cage dcg-gate] dcg-guard internal error (failing open): ${dcgResult.message}`);
			return undefined;
		}

		return undefined;
	});
}
