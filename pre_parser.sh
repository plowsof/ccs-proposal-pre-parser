#!/usr/bin/env bash
# pre_parser.sh: pre_parser_1.sh and pre_parser_2.php in one, in bash, for pull requests on
# Forgejo (the GitLab job, gitlab_workflow.yml, runs the two originals). The same checks, in the
# same order. Where pre_parser_2.php reads the YAML with PHP's yaml_parse, this reads it with
# ccs-bash's lib/frontmatter.awk, the parser that will read the file on the site: a proposal
# passes only if ccs-bash reads it, and reads the same front matter as ccs-back.
#
#   BASE=<the target branch's commit> HEAD=<the pull request's commit> \
#   DESCRIPTION=<a file with the pull request's description> FRONTMATTER_AWK=<frontmatter.awk> \
#   [FORGE=<the forge, e.g. https://git.disroot.org>: images must be uploaded there] \
#       ./pre_parser.sh
#
# Run in a clone of ccs-proposals that has both commits. It runs nothing from the pull request:
# the proposal is only read, with git show. Needs bash, git, awk, sed, date (GNU).
#
# Output, for Forgejo's log view (web_src/js/components/ActionJobStep.vue, v17): it has no
# annotations and shows ::error:: and ::group:: as they are, but folds ##[group] ... ##[endgroup]
# and draws ANSI colours. So a problem is one red "Error: ..." line, in plain words with what to
# do, and the last line of the log (a CRLF file a yellow "Warning: ..." line); the details (the
# files, the YAML, the values read) are folded groups above it.
set -euo pipefail
: "${BASE:?}" "${HEAD:?}" "${DESCRIPTION:?}" "${FRONTMATTER_AWK:?}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { printf '\033[1;31mError: %s\033[0m\n' "$*"; exit 1; }
group() { echo "##[group]$*"; }
endgroup() { echo "##[endgroup]"; }

# pre_parser_1.sh: lines between --- lines dropped, then empty lines, runs of spaces made one
strip_yaml_front_matter_and_preprocess() {
    awk 'BEGIN { in_yaml = 0 } /^---$/ { in_yaml = !in_yaml; next } !in_yaml { print }' | awk 'NF' | tr -s ' '
}
has_yaml_front_matter() {
    awk 'BEGIN { s = 0; e = 0 } /^---$/ { if (!s) s = 1; else e = 1 } END { exit !(s && e) }' "$1"
}

#### pre_parser_1.sh

strip_yaml_front_matter_and_preprocess < "$DESCRIPTION" > "$tmp/mr_description.md"
[[ $(tr -d '\n' < "$tmp/mr_description.md") ]] \
    || fail "The pull request's description is empty: paste the proposal's text into it (all of the file below its front matter)."

NEW_FILES=$(git diff --diff-filter=A --name-only "$BASE...$HEAD")
CHANGED_FILES=$(git diff --diff-filter=AM --name-only "$BASE...$HEAD")
group "Files the pull request adds or changes"
echo "$CHANGED_FILES"
endgroup

FILE_COUNT=$(grep -c -v '^[[:space:]]*$' <<<"$CHANGED_FILES" || true)
[[ $FILE_COUNT == 1 ]] \
    || fail "The pull request changes $FILE_COUNT files: a proposal is one new .md file and nothing else."

NEW_FILE=$(head -n 1 <<<"$NEW_FILES")
[[ -n $NEW_FILE ]] \
    || fail "The pull request adds no new file, it only edits one: a proposal is a new .md file (edits to existing proposals are made by the CCS maintainers)."
[[ $NEW_FILE == *.md ]] || fail "$NEW_FILE is not a Markdown file: a proposal's name ends in .md."

git show "$HEAD:$NEW_FILE" > "$tmp/file"   # the proposal, as text: nothing of it is run
grep -q $'\r' "$tmp/file" \
    && printf '\033[1;33mWarning: %s\033[0m\n' "$NEW_FILE has Windows line endings (CRLF). It is still read, but please save it with Unix ones (LF)."
sed 's/\r$//' "$tmp/file" > "$tmp/unix"

has_yaml_front_matter "$tmp/unix" \
    || fail "$NEW_FILE has no front matter: it must start with a line of just ---, then the fields (layout, title, ...), then another line of just ---."

strip_yaml_front_matter_and_preprocess < "$tmp/unix" > "$tmp/file_content.md"
DIFF_OUTPUT=$(git --no-pager diff --no-index --color=always --word-diff=plain --color-moved --ignore-space-change \
    "$tmp/mr_description.md" "$tmp/file_content.md" || true)
if [[ -n $DIFF_OUTPUT ]]; then
    echo "The differences, the description's text in red and the file's in green:"
    printf '%s\n' "$DIFF_OUTPUT"
    fail "The pull request's description isn't the same as the text of $NEW_FILE: copy the file's text below its front matter into the description (the differences are above)."
fi
echo "The pull request's description is the text of $NEW_FILE."

#### pre_parser_2.php

# checkFilenameInUpstream: no file of that name, in any case, on the target branch
while IFS= read -r f; do
    [[ ${f,,} == "${NEW_FILE,,}" ]] \
        && fail "$NEW_FILE is already a proposal ($f; names count as the same whatever the case): choose another name."
done < <(git ls-tree -r "$BASE" --name-only | grep '.md' || true)

# checkFilename
[[ $NEW_FILE =~ .+\.md$ ]] || fail "$NEW_FILE: a proposal's name ends in .md."
[[ $NEW_FILE != */* ]] || fail "$NEW_FILE is in a folder: proposals go in the top folder of the repository."

# getAmountFromText: the file with every \r gone
tr -d '\r' < "$tmp/file" > "$tmp/nocr"
first=$(head -n 1 "$tmp/nocr")
first=${first#"${first%%[! $'\t\n\v']*}"}; first=${first%"${first##*[! $'\t\n\v']}"}   # PHP's trim
[[ $first == --- ]] || fail "$NEW_FILE must start with a line of just ---: the front matter comes first."
[[ $(tail -c 1 "$tmp/nocr" | od -An -c | tr -d ' ') == '\n' ]] \
    || fail "$NEW_FILE doesn't end with a new line: add one after its last line."

# preg_split('/\r?\n?---\r?\n/m'): the text up to the first "---\n" (with the newline before it,
# if any), then up to the next one. The YAML is the part between; a line merely ending in ---
# splits it too.
nofm="The front matter isn't between two lines of just --- (no spaces after them): put a line --- above the fields and one below."
s=$(cat "$tmp/nocr"; echo x); s=${s%x}
cut1=${s%%$'---\n'*}
[[ $cut1 != "$s" ]] || fail "$nofm"
rest=${s:${#cut1}+4}
yaml=${rest%%$'---\n'*}
[[ $yaml != "$rest" ]] || fail "$nofm"
yaml=${yaml%$'\n'}

group "The front matter"
printf '%s\n' "$yaml"
endgroup

# checkYamlForSpaces: a line ending in ":" and spaces
spaces=() n=0
while IFS= read -r line || [[ $line ]]; do
    n=$((n + 1))
    if [[ $line =~ :[[:space:]]+$ ]]; then
        t=${line#"${line%%[! $'\t']*}"}; t=${t%"${t##*[! $'\t']}"}
        spaces+=("line $((n + 1)) '$t'")   # the file's line: the front matter starts on line 2
    fi
done <<<"$yaml"
if ((${#spaces[@]})); then
    list=$(printf '%s, ' "${spaces[@]}"); list=${list%, }
    fail "Spaces after a ':' at the end of a line ($list): remove them, an empty value ends right after the ':'."
fi

# The YAML, read by ccs-bash's parser: it must read the same lines as the split above (a line
# ending in --- inside them is where the two part), and read them at all.
awk 'NR == 1 { next } { l = $0; sub(/[ \t]+$/, "", l) } l == "---" || l == "..." { exit } { print }' "$tmp/nocr" > "$tmp/awk-yaml"
[[ $(cat "$tmp/awk-yaml") == "$(printf '%s' "$yaml")" ]] \
    || fail "A line in the front matter ends in ---, or it ends with ... : the site would read it differently. Change that line."
grep -q $'^ *\t' <<<"$yaml" && fail "A tab in the indentation of the front matter: indent with spaces (YAML doesn't allow tabs)."
if ! line=$(LC_ALL=C awk -f "$FRONTMATTER_AWK" "$tmp/nocr" 2> "$tmp/awk-err") || [[ -z $line ]]; then
    fail "The front matter can't be read as a proposal: $(sed 's/^skipping [^:]*: //' "$tmp/awk-err" | head -n 1)."
fi
# its fields, tab-separated (read would merge empty ones): file layout title author date amount
# gitlab_url milestones done tags
field() { awk -F '\t' -v i="$1" '{ print $i }' <<<"$line"; }
layout=$(field 2) title=$(field 3) author=$(field 4) milestones=$(field 8)
# the raw values (frontmatter.awk gives date and amount converted)
raw() { awk -v k="$1" 'NR > 1 && $0 == "---" { exit } index($0, k ": ") == 1 { sub(/^[^:]*: */, ""); print; exit }' "$tmp/nocr" \
    | sed -E "s/^\"(.*)\"( +#.*)?$/\1/; s/^'(.*)'( +#.*)?$/\1/; s/ +#.*$//" | sed "s/''/'/g"; }
date_raw=$(raw date) amount_raw=$(raw amount)

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
    ! empty "$k" \
        || fail "$k: is missing or empty (to YAML, 0, no, off, false, null and ~ are empty too: put such a value in \"quotes\")."
done
((milestones > 0)) || fail "milestones: is missing or empty: list at least one milestone."
# checkLayout: frontmatter.awk allows only fr, wip and cp, as here
# checkMilestones: each milestone has a done: (any value, or none)
items=$(awk '/^milestones:/ { m = 1; next } m && /^[^ -]/ { m = 0 } m && /^ *- / { n++ } END { print n + 0 }' <<<"$yaml")
dones=$(awk '/^milestones:/ { m = 1; next } m && /^[^ -]/ { m = 0 } m && /^ *(- )?done:( |$)/ { n++ } END { print n + 0 }' <<<"$yaml")
((dones >= items)) \
    || fail "A milestone without a done: line ($dones of $items have one): give every milestone one, left empty until it is done."

# The date as "Month day, year", e.g. "January 23, 2024", and a real date (DateTime's round trip)
months='January|February|March|April|May|June|July|August|September|October|November|December'
if [[ ! $date_raw =~ ^($months)\ ([1-9]|[12][0-9]|3[01]),\ ([0-9]{4})$ ]] \
    || [[ $(LC_ALL=C date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}" '+%B %-d, %Y' 2> /dev/null) != "$date_raw" ]]; then
    fail "date: '$date_raw' isn't a date written like 'January 23, 2024' (the month in full, the day without a 0 in front, a comma, the year)."
fi
# htmlspecialchars(title, ENT_QUOTES) must change nothing
if [[ $title == *[\&\"\'\<\>]* ]]; then
    fail "title: '$title' has one of & \" ' < > in it: leave them out of the title."
fi

# Images: uploaded to this forge, as dragging one into the pull request does (FORGE, e.g.
# https://git.disroot.org): the site shows only those, from its own copy; any other image would
# only be a link. Raw <img> tags show as text on the site.
if [[ -n ${FORGE:-} ]]; then
    uuid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    while IFS= read -r a; do
        [[ $a =~ ^(${FORGE//./\.})?(/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?/attachments/$uuid$ ]] \
            || fail "The image $a isn't uploaded here: drag the picture into the pull request's description, then use the address it gets there (it has /attachments/ in it)."
    done < <(awk 'FNR == 1 { fm = ($0 ~ /^---[ \t]*$/); next } fm { if ($0 ~ /^(---|\.\.\.)[ \t]*$/) fm = 0; next }
        { s = $0; while (match(s, /!\[[^]]*\]\([^) ]+( [^)]*)?\)/)) { m = substr(s, RSTART, RLENGTH)
          u = substr(m, index(m, "](") + 2); sub(/\)$/, "", u); sub(/ .*/, "", u); print u; s = substr(s, RSTART + RLENGTH) } }' "$tmp/nocr")
    grep -qiE '<img[ >]' "$tmp/nocr" \
        && fail "An <img> tag: the site shows it as text. Drag the picture into the pull request's description and use the ![description](address) it gives."
fi

amt=${amount_raw//,/.}; [[ $amt =~ ^[[:space:]]*[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+) ]] && amt=${BASH_REMATCH[0]// /} || amt=0
group "The proposal as the site will read it"
echo "Amount: $amt"
echo "Author: $author"
echo "Date: $date_raw"
echo "State: $(case $layout in fr) echo FUNDING-REQUIRED ;; wip) echo WORK-IN-PROGRESS ;; cp) echo COMPLETED ;; esac)"
echo "Title: $title"
echo "Milestones: $milestones"
endgroup
echo "Proposal $NEW_FILE is valid."
