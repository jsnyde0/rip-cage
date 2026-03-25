#!/usr/bin/env bash
# Hook: Block compound commands that chain multiple commands with && ; ||
#
# Compound commands bypass permission prefix matching — the system only checks
# the first command's prefix, so "git add . && git commit" would auto-approve
# if "git add" is whitelisted, silently running "git commit" without review.
#
# For cd-based compounds, provides directory flag hints so the cd can be
# avoided entirely (e.g. git -C, uv run --directory).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

# Use perl for all detection and message generation
RESULT=$(echo "$COMMAND" | perl -e '
  use strict; use warnings;
  my $input = do { local $/; <STDIN> }; chomp $input;

  # --- Strip quoted strings for operator detection ---
  my $stripped = $input;
  $stripped =~ s/'\''[^'\'']*'\''//g;        # single-quoted
  $stripped =~ s/"[^"]*"//g;                 # double-quoted
  # HEREDOC bodies
  $stripped =~ s/<<-?\s*'\''?(\w+)'\''?.*?\n\1//gs;

  # Check for compound operators outside quotes
  unless ($stripped =~ /(?:&&|(?<!;);(?!;)|\|\|)/) {
    exit 0;  # not compound — allow
  }

  # --- It is compound. Build the deny message. ---

  # Split on && ; || (naive but good enough for hints)
  my @parts = split /\s*(?:&&|;|\|\|)\s*/, $input;

  # Known directory flags for cd hint
  my %dir_flags = (
    git   => "-C",
    yarn  => "--cwd",
    uv    => "run --directory",
    npm   => "--prefix",
    node  => "--cwd",
    npx   => "--cwd",
  );
  my %global_cmds = (bd => 1, brew => 1, which => 1);

  # Check if first command is cd
  my $is_cd = ($parts[0] =~ /^\s*cd\s+/);
  my $dir;
  my @inner;

  if ($is_cd) {
    ($dir) = $parts[0] =~ /^\s*cd\s+(.*?)\s*$/;
    @inner = @parts[1..$#parts];
  }

  # Build numbered list
  my $n = 0;
  my $list = "";
  for my $part (@parts) {
    $n++;
    $list .= "($n) $part\n";
  }
  chomp $list;

  my $msg = "Split into separate Bash calls:\n$list";

  # Add directory flag hints if cd-based
  if ($is_cd && @inner) {
    my ($first_cmd) = $inner[0] =~ /^\s*(\S+)/;
    if ($first_cmd && exists $dir_flags{$first_cmd}) {
      my $flag = $dir_flags{$first_cmd};
      $msg .= "\nTip: $first_cmd supports \"$flag\" to set working directory — avoids the cd entirely.";
    } elsif ($first_cmd && exists $global_cmds{$first_cmd}) {
      $msg .= "\nNote: $first_cmd works from any directory — the cd is likely unnecessary.";
    }
  }

  print $msg;
')

if [ -n "$RESULT" ]; then
  jq -n --arg reason "$RESULT" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Do not use compound commands (&&, ;, ||). " + $reason)
    }
  }'
else
  exit 0
fi
