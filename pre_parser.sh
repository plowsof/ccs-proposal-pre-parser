#!/usr/bin/env bash
# pre_parser.sh: pre_parser_1.sh and pre_parser_2.php in one, in bash, for pull requests on
# Forgejo (the GitLab job, gitlab_workflow.yml, runs the two originals). The same checks, in the
# same order, with the same messages. Where pre_parser_2.php reads the YAML with PHP's yaml_parse,
# this reads it with ccs-bash's lib/frontmatter.awk, the parser that will read the file on the
# site: a proposal passes only if ccs-bash reads it, and reads the same front matter as ccs-back.
#
#   BASE=<the target branch's commit> HEAD=<the pull request's commit> \
#   DESCRIPTION=<a file with the pull request's description> FRONTMATTER_AWK=<frontmatter.awk> \
#       ./pre_parser.sh
#
# Run in a clone of ccs-proposals that has both commits. It runs nothing from the pull request:
# the proposal is only read, with git show. Needs bash, git, awk, sed, date (GNU).
set -euo pipefail
: "${BASE:?}" "${HEAD:?}" "${DESCRIPTION:?}" "${FRONTMATTER_AWK:?}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "$*"; exit 1; }

# pre_parser_1.sh: lines between --- lines dropped, then empty lines, runs of spaces made one
strip_yaml_front_matter_and_preprocess() {
    awk 'BEGIN { in_yaml = 0 } /^---$/ { in_yaml = !in_yaml; next } !in_yaml { print }' | awk 'NF' | tr -s ' '
}
has_yaml_front_matter() {
    awk 'BEGIN { s = 0; e = 0 } /^---$/ { if (!s) s = 1; else e = 1 } END { exit !(s && e) }' "$1"
}

#### pre_parser_1.sh

echo "Stripping YAML front matter from the pull request description..."
strip_yaml_front_matter_and_preprocess < "$DESCRIPTION" > "$tmp/mr_description.md"
[[ $(tr -d '\n' < "$tmp/mr_description.md") ]] \
    || fail "Error: The merge request description is empty after stripping YAML front matter."

echo "Fetching new files in the pull request..."
NEW_FILES=$(git diff --diff-filter=A --name-only "$BASE...$HEAD")
echo "Fetching new and modified files in the pull request..."
CHANGED_FILES=$(git diff --diff-filter=AM --name-only "$BASE...$HEAD")
echo "List of changed files in the pull request:"
echo "$CHANGED_FILES"

FILE_COUNT=$(grep -c -v '^[[:space:]]*$' <<<"$CHANGED_FILES" || true)
[[ $FILE_COUNT == 1 ]] || fail "Error: The merge request must contain exactly one new or modified file."

NEW_FILE=$(head -n 1 <<<"$NEW_FILES")
echo "New file in the pull request:"
echo "$NEW_FILE"
[[ $NEW_FILE == *.md ]] || fail "$NEW_FILE file is not a Markdown (.md) file."

git show "$HEAD:$NEW_FILE" > "$tmp/file"   # the proposal, as text: nothing of it is run
grep -q $'\r' "$tmp/file" && echo "Warning: The file $NEW_FILE contains Windows-style line endings (CRLF)."
sed 's/\r$//' "$tmp/file" > "$tmp/unix"

echo "Checking if the Markdown file $NEW_FILE contains YAML front matter..."
has_yaml_front_matter "$tmp/unix" || fail "Error: The Markdown file $NEW_FILE does not contain YAML front matter."

strip_yaml_front_matter_and_preprocess < "$tmp/unix" > "$tmp/file_content.md"
echo "Content of the Markdown file $NEW_FILE (after stripping YAML front matter):"
cat "$tmp/file_content.md"
DIFF_OUTPUT=$(git --no-pager diff --no-index --color=always --word-diff=plain --color-moved --ignore-space-change \
    "$tmp/mr_description.md" "$tmp/file_content.md" || true)
if [[ -n $DIFF_OUTPUT ]]; then
    echo "Error: The merge request description does not match the content of the Markdown file $NEW_FILE."
    printf '%s\n' "$DIFF_OUTPUT"
    exit 1
fi
echo "The merge request description matches the content of the Markdown file."

#### pre_parser_2.php

echo "Validating the Markdown file $NEW_FILE..."
# checkFilenameInUpstream: no file of that name, in any case, on the target branch
while IFS= read -r f; do
    [[ ${f,,} == "${NEW_FILE,,}" ]] \
        && { echo "Error: $NEW_FILE already exists in the upstream branch origin/master (case-insensitive)."; exit 1; }
done < <(git ls-tree -r "$BASE" --name-only | grep '.md' || true)

err() { fail "Validation error: $*"; }
# checkFilename
[[ $NEW_FILE =~ .+\.md$ ]] || err "Filename must end with .md"
[[ $NEW_FILE != */* ]] || err "File must be in the root folder"

# getAmountFromText: the file with every \r gone
tr -d '\r' < "$tmp/file" > "$tmp/nocr"
first=$(head -n 1 "$tmp/nocr")
first=${first#"${first%%[! $'\t\n\v']*}"}; first=${first%"${first##*[! $'\t\n\v']}"}   # PHP's trim
[[ $first == --- ]] || err "Failed to parse proposal, the file must start with '---'"
[[ $(tail -c 1 "$tmp/nocr" | od -An -c | tr -d ' ') == '\n' ]] || err "File must end with a newline character"

# preg_split('/\r?\n?---\r?\n/m'): the text up to the first "---\n" (with the newline before it,
# if any), then up to the next one. The YAML is the part between; a line merely ending in ---
# splits it too.
s=$(cat "$tmp/nocr"; echo x); s=${s%x}
cut1=${s%%$'---\n'*}
[[ $cut1 != "$s" ]] || err "Failed to parse proposal, can't find YAML description surrounded by '---' lines"
rest=${s:${#cut1}+4}
yaml=${rest%%$'---\n'*}
[[ $yaml != "$rest" ]] || err "Failed to parse proposal, can't find YAML description surrounded by '---' lines"
yaml=${yaml%$'\n'}

# checkYamlForSpaces: a line ending in ":" and spaces
spaces=0 n=0
while IFS= read -r line || [[ $line ]]; do
    n=$((n + 1))
    if [[ $line =~ :[[:space:]]+$ ]]; then
        t=${line#"${line%%[! $'\t']*}"}; t=${t%"${t##*[! $'\t']}"}
        echo "Line $n: '$t' contains key followed by spaces and a newline"
        spaces=1
    fi
done <<<"$yaml"
((spaces == 0)) || err "Remove trailing spaces after empty key values"
echo "YAML Content:"
printf '%s\n' "$yaml"

# The YAML, read by ccs-bash's parser: it must read the same lines as the split above (a line
# ending in --- inside them is where the two part), and read them at all.
awk 'NR == 1 { next } { l = $0; sub(/[ \t]+$/, "", l) } l == "---" || l == "..." { exit } { print }' "$tmp/nocr" > "$tmp/awk-yaml"
[[ $(cat "$tmp/awk-yaml") == "$(printf '%s' "$yaml")" ]] \
    || err "Failed to parse proposal: a line ending in '---' inside the front matter (the site would read it differently)"
grep -q $'^ *\t' <<<"$yaml" && err "Failed to parse proposal: a tab in the indentation (YAML doesn't allow it)"
if ! line=$(LC_ALL=C awk -f "$FRONTMATTER_AWK" "$tmp/nocr" 2> "$tmp/awk-err") || [[ -z $line ]]; then
    err "Failed to parse proposal: $(sed 's/^skipping [^:]*: //' "$tmp/awk-err" | head -n 1)"
fi
# its fields, tab-separated (read would merge empty ones): file layout title author date amount
# gitlab_url milestones done tags
field() { awk -F '\t' -v i="$1" '{ print $i }' <<<"$line"; }
layout=$(field 2) title=$(field 3) author=$(field 4) amount=$(field 6) milestones=$(field 8)
# the raw values (frontmatter.awk gives date and amount converted)
raw() { awk -v k="$1" 'NR > 1 && $0 == "---" { exit } index($0, k ": ") == 1 { sub(/^[^:]*: */, ""); print; exit }' "$tmp/nocr" \
    | sed -E "s/^\"(.*)\"( +#.*)?$/\1/; s/^'(.*)'( +#.*)?$/\1/; s/ +#.*$//" | sed "s/''/'/g"; }
date_raw=$(raw date) amount_raw=$(raw amount)
echo "Parsed values:"
printf 'layout: %s\ntitle: %s\nauthor: %s\ndate: %s\namount: %s\nmilestones: %s\n' \
    "$layout" "$title" "$author" "$date_raw" "$amount_raw" "$milestones"

# checkMandatoryFields: empty() of what yaml_parse makes of the value. Unquoted, these are null,
# false or zero to it, so empty; quoted, a string, empty only if "" or "0".
empty() {   # empty KEY: the key's value as written, from the YAML
    local v
    v=$(awk -v k="$1" 'index($0, k ":") == 1 { sub(/^[^:]*: */, ""); print; exit }' <<<"$yaml")
    if [[ $v == \"* || $v == \'* ]]; then
        v=${v:1}; v=${v%%[\"\']*}
        [[ -z $v || $v == 0 ]]
    else
        v=${v%% #*}
        [[ -z $v || $v =~ ^(~|null|Null|NULL|false|False|FALSE|no|No|NO|off|Off|OFF|n|N)$ ]] \
            || [[ $v =~ ^[-+]?(0[0_]*(\.[0_]*)?|\.0[0_]*|0x0+|0b0+|0[0_]*(:[0-5]?0)+)$ ]]
    fi
}
for k in amount author date layout title; do
    ! empty "$k" || err "Mandatory field $k is missing"
done
((milestones > 0)) || err "Mandatory field milestones is missing"
# checkLayout: frontmatter.awk allows only fr, wip and cp, as here
# checkMilestones: each milestone has a done: (any value, or none)
items=$(awk '/^milestones:/ { m = 1; next } m && /^[^ -]/ { m = 0 } m && /^ *- / { n++ } END { print n + 0 }' <<<"$yaml")
dones=$(awk '/^milestones:/ { m = 1; next } m && /^[^ -]/ { m = 0 } m && /^ *(- )?done:( |$)/ { n++ } END { print n + 0 }' <<<"$yaml")
((dones >= items)) || err "Each milestone must have a 'done' field"

# The date as "Month day, year", e.g. "January 23, 2024", and a real date (DateTime's round trip)
months='January|February|March|April|May|June|July|August|September|October|November|December'
if [[ ! $date_raw =~ ^($months)\ ([1-9]|[12][0-9]|3[01]),\ ([0-9]{4})$ ]] \
    || [[ $(LC_ALL=C date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}" '+%B %-d, %Y' 2> /dev/null) != "$date_raw" ]]; then
    err "Invalid date format. Use 'Month day, year' (e.g. 'January 23, 2024')"
fi
# htmlspecialchars(title, ENT_QUOTES) must change nothing
if [[ $title == *[\&\"\'\<\>]* ]]; then
    t=${title//&/&amp;}; t=${t//\"/&quot;}; t=${t//\'/&#039;}; t=${t//</&lt;}; t=${t//>/&gt;}
    echo "Escaped title: $t"
    err "Remove special chars from title"
fi

echo "Processed values:"
amt=${amount_raw//,/.}; [[ $amt =~ ^[[:space:]]*[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+) ]] && amt=${BASH_REMATCH[0]// /} || amt=0
echo "Amount: $amt"
echo "Author: $author"
echo "Date: $date_raw"
echo "State: $(case $layout in fr) echo FUNDING-REQUIRED ;; wip) echo WORK-IN-PROGRESS ;; cp) echo COMPLETED ;; esac)"
echo "Title: $title"
echo "Milestones: $milestones"
echo "Proposal $NEW_FILE is valid."
echo "Proposal validation succeeded."
