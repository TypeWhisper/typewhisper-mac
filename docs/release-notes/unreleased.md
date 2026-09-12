# Unreleased

- Number formatting now offers Always, 10 and above (the default), and 100 and above under Settings → Dictation → Output Formatting. Smaller spoken whole numbers and ordinals keep their original wording. Negative numbers use their magnitude; decimals and recognized digit sequences still convert to digits. The threshold also applies when a workflow enables number normalization. Settings backups preserve both the number-normalization toggle and threshold. Existing digits are unchanged. (#1304)
