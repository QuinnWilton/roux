# Commit policy; run with `mix presubmit`, installed as hooks by `mix presubmit.install`.
[
  {Presubmit.Rules.Elixir, except: [:removals_deprecated, :pure_move]},
  Presubmit.Rules.Hygiene,
  Presubmit.Rules.Mix,
  # Changelog entries are written in batches at release time, not per commit.
  {Presubmit.Rules.Changelog, warn: [:api_changes_logged]},
  # `[tag] text`: the text is free, since it often opens with a proper noun, a version or a
  # flag. A long subject is worth a look, not a refused commit.
  {Presubmit.Rules.Message,
   subject: ~r/^\[[a-z0-9_.\/-]+\] \S/,
   max_subject_length: 72,
   warn: [:subject_length]}
]
