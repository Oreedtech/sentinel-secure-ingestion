# Required for Checkov to load this directory via --external-checks-dir.
# Without it the loader silently imports nothing: the scan still succeeds, still reports
# "Passed checks", and still exits 0 -- but every custom policy below is absent from the
# run. A green build then means only that the built-in ruleset passed.
#
# Verify the custom policies are actually executing:
#   checkov -d terraform --external-checks-dir policy/checkov --framework terraform \
#     --compact | grep CKV_OREED
