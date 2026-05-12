#!/usr/bin/env bash
# Hook: Block ssh CLI flags that defeat the cage's host arrow.
#
# OpenSSH semantics: command-line `-o` always wins over Match final blocks in
# /etc/ssh/ssh_config. So even with the rip-cage filtered known_hosts mounted,
# `ssh -o UserKnownHostsFile=/tmp/anything -o StrictHostKeyChecking=accept-new <host>`
# walks past every layer below the OpenSSH-CLI invocation: openssh writes the
# new host key to the user-supplied path, treats accept-new as carte blanche,
# and the forwarded ssh-agent (default per ADR-017) signs whatever the
# destination asks for.
#
# This hook denies that shape at the PreToolUse layer (before openssh runs)
# and points the agent at the legitimate path: declare the host in
# .rip-cage.yaml ssh.allowed_hosts, or run `rc config init` to bootstrap from
# git remotes. See ADR-022 D5.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

REASON=$(echo "$COMMAND" | perl -e '
  use strict; use warnings;
  my $input = do { local $/; <STDIN> }; chomp $input;

  # Strip ONLY single-quoted bodies + heredocs (truly literal, no shell
  # interpolation). Double-quoted bodies are preserved because legitimate
  # ssh-family idioms put the flag *inside* double quotes (rsync -e "ssh -o ...",
  # ssh -o "Foo=bar"). False positives from `echo "ssh -o ..."` are guarded by
  # the ssh-family token check below: the basename of `"ssh` does not match
  # `^ssh$`, so quoted appearances of the literal word "ssh" do not count.
  my $stripped = $input;
  $stripped =~ s/'\''[^'\'']*'\''//g;        # single-quoted
  $stripped =~ s/<<-?\s*'\''?(\w+)'\''?.*?\n\1//gs;  # heredoc bodies

  # Identify ssh-family invocations. We match any token whose basename is
  # ssh|scp|sftp; that covers /usr/bin/ssh and direct path forms. rsync is
  # caught only when -e "ssh ..." (or --rsh ssh) appears.
  my $is_ssh_family = 0;
  for my $tok (split /\s+/, $stripped) {
    my ($base) = $tok =~ m{(?:^|/)([^/]+)$};
    if (defined $base && $base =~ /^(ssh|scp|sftp)$/) {
      $is_ssh_family = 1;
      last;
    }
  }
  if (!$is_ssh_family && $stripped =~ /\brsync\b/ && $stripped =~ /(?:-e|--rsh)\s+\S*ssh\b/) {
    $is_ssh_family = 1;
  }
  exit 0 unless $is_ssh_family;

  # Detect the three flag shapes that defeat the host arrow.
  my @hits;
  if ($stripped =~ /-o\s*UserKnownHostsFile\s*=/) {
    push @hits, "-o UserKnownHostsFile";
  }
  if ($stripped =~ /-o\s*GlobalKnownHostsFile\s*=/) {
    push @hits, "-o GlobalKnownHostsFile";
  }
  if ($stripped =~ /-o\s*StrictHostKeyChecking\s*=\s*(no|accept-new|off)\b/i) {
    push @hits, "-o StrictHostKeyChecking=$1";
  }
  exit 0 unless @hits;

  my $flags = join(", ", @hits);
  my $msg = "Blocked ssh-family command: $flags defeats the cage host arrow.\n";
  $msg   .= "OpenSSH CLI -o always overrides /etc/ssh/ssh_config Match final, and\n";
  $msg   .= "the forwarded ssh-agent (ADR-017 default) will sign for whatever host the\n";
  $msg   .= "override accepts. To let the cage reach a host legitimately:\n";
  $msg   .= "  - Add to .rip-cage.yaml at the workspace root:\n";
  $msg   .= "        version: 1\n";
  $msg   .= "        ssh:\n";
  $msg   .= "          allowed_hosts: [<host>]\n";
  $msg   .= "  - Or run on the host: rc config init  (bootstraps from git remotes)\n";
  $msg   .= "  - Then on the host:   rc destroy <cage> && rc up <workspace>\n";
  $msg   .= "To override this single command (requires human-on-keyboard): dcg allow-once <code>\n";
  $msg   .= "See ADR-022 (SSH allowlist).";
  print $msg;
')

if [ -n "$REASON" ]; then
  jq -n --arg reason "$REASON" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
else
  exit 0
fi
