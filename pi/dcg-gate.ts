/**
 * dcg-gate.ts — Rip Cage pi-cage DCG + compound-blocker guard (rip-cage-bl1)
 *
 * Brings pi cages to DCG + compound-command parity with Claude Code cages.
 * Fires for EVERY pi tool call (not just "bash"), closing the multi-tool bypass
 * that a name-"bash"-only override would leave open.
 *
 * Two-gate design:
 *   1. DCG destructive-command guard — delegated to dcg-guard wrapper
 *      (/usr/local/lib/rip-cage/bin/dcg-guard, ADR-025 D3+D4 FIRM).
 *      The envelope always uses tool_name="bash" (a value in dcg's
 *      is_supported_shell_tool allowlist) regardless of the originating
 *      pi tool name — otherwise dcg's tool_name filter returns no-command
 *      and silently FAILS OPEN for MCP/custom exec tools.
 *      Decision is read from dcg stdout JSON hookSpecificOutput.permissionDecision,
 *      NOT the exit code.
 *
 *   2. Compound-command blocker — delegated to block-compound-commands.sh
 *      (/usr/local/lib/rip-cage/hooks/block-compound-commands.sh).
 *      Quote-aware &&, ;, || detection; strips quoted strings before scanning.
 *
 * On any deny → { block: true, reason } (agent receives readable refusal).
 * On guard internal error → fail OPEN (undefined); logs to stderr — never wedge the agent.
 *
 * ADR refs: ADR-024 D2 (on-device-harm symmetry), ADR-019 D4 (goal-FIRM),
 *           ADR-025 D3/D4 (dcg-guard wrapper, FIRM), ADR-001 (fail-loud).
 */

import { spawnSync } from "node:child_process";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// Paths to the cage-owned, root-owned (agent-unwritable) guard scripts.
// These are baked into the image; the agent cannot modify or delete them.
const DCG_GUARD = "/usr/local/lib/rip-cage/bin/dcg-guard";
const COMPOUND_SCRIPT = "/usr/local/lib/rip-cage/hooks/block-compound-commands.sh";

/**
 * Extract a command string from a tool input, if present.
 *
 * Field coverage rationale (F3, rip-cage-bl1 repair):
 *   - "command": pi's built-in bash tool (bash.ts:34 bashSchema) AND all known exec-capable
 *     extension tools (ssh.ts, sandbox.ts) replace/override the built-in bash tool and use the
 *     same BashToolInput schema — field "command" covers all real exec-capable tools in pi v0.70.2.
 *   - pi has no MCP server bridge (no MCP packages found in pi-mono); CustomToolCallEvent
 *     (types.ts:799) carries input: Record<string, unknown> for any extension-registered tool.
 *
 * Known acceptable gap: a custom extension that registers a NEW exec-capable tool (not
 * replacing "bash") with a different field name (e.g. "script", "cmd") would pass through
 * unguarded here. This gap is acceptable per the rip-cage 80/20 philosophy — we block the
 * obvious accident (all pi built-in and known exec tools), do not false-positive on non-command
 * strings in other custom tools. The live-fire proof (F2) uses the non-bash tool name path
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

/**
 * Call the compound-command blocker script.
 * Envelope uses tool_name="Bash" (matching block-compound-commands.sh expectations).
 *
 * Returns { decision: "deny", reason } | { decision: "allow" } | { decision: "error", message }
 */
function callCompoundBlocker(command: string): { decision: "deny"; reason: string } | { decision: "allow" } | { decision: "error"; message: string } {
	const envelope = JSON.stringify({
		tool_name: "Bash",
		tool_input: { command },
	});

	let result: ReturnType<typeof spawnSync>;
	try {
		result = spawnSync(COMPOUND_SCRIPT, [], {
			input: envelope,
			encoding: "utf8",
			timeout: 3000,
		});
	} catch (err) {
		return { decision: "error", message: `compound-blocker spawn failed: ${err instanceof Error ? err.message : String(err)}` };
	}

	if (result.error) {
		return { decision: "error", message: `compound-blocker error: ${result.error.message}` };
	}

	const stdout = result.stdout ?? "";
	if (!stdout.trim()) {
		// No output → allow (not compound)
		return { decision: "allow" };
	}

	let parsed: Record<string, unknown>;
	try {
		parsed = JSON.parse(stdout);
	} catch {
		return { decision: "allow" };
	}

	const hookOutput = parsed?.hookSpecificOutput as Record<string, unknown> | undefined;
	const permissionDecision = hookOutput?.permissionDecision;

	if (permissionDecision === "deny") {
		const reason = (hookOutput?.permissionDecisionReason as string | undefined)
			?? "Command blocked: compound commands (&&, ;, ||) are not allowed";
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

		// Gate 1: DCG destructive-command guard
		// CRITICAL: always pass tool_name="bash" to dcg regardless of ev.toolName —
		// otherwise dcg's is_supported_shell_tool filter returns no-command and silently
		// FAILS OPEN for MCP/custom tool names not in dcg's allowlist.
		const dcgResult = callDcgGuard(command);
		if (dcgResult.decision === "deny") {
			return { block: true, reason: dcgResult.reason };
		}
		if (dcgResult.decision === "error") {
			// Fail open: log but don't block the agent
			console.error(`[rip-cage dcg-gate] dcg-guard internal error (failing open): ${dcgResult.message}`);
			return undefined;
		}

		// Gate 2: Compound-command blocker
		const compoundResult = callCompoundBlocker(command);
		if (compoundResult.decision === "deny") {
			return { block: true, reason: compoundResult.reason };
		}
		if (compoundResult.decision === "error") {
			// Fail open: log but don't block the agent
			console.error(`[rip-cage dcg-gate] compound-blocker internal error (failing open): ${compoundResult.message}`);
			return undefined;
		}

		return undefined;
	});
}
