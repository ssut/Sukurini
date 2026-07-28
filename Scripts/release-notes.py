#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
from datetime import datetime, timezone

FIELD = "\x1f"
RECORD = "\x1e"

SUBJECT_PATTERN = re.compile(
    r"^(?P<kind>[A-Za-z0-9]+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?:[ \t]*(?P<subject>.+)$"
)

INTERNAL_KINDS = {
    "appcast",
    "build",
    "chore",
    "ci",
    "dep",
    "deps",
    "doc",
    "docs",
    "meta",
    "refactor",
    "release",
    "revert",
    "site",
    "style",
    "test",
    "tests",
    "tmp",
    "wip",
}

TYPED_KINDS = {"feat", "feature", "fix", "bugfix", "hotfix", "perf"}

GROUP_ORDER = [
    ("breaking", "Breaking changes"),
    ("added", "Added"),
    ("changed", "Changed"),
    ("fixed", "Fixed"),
]

FALLBACK_GROUP = "changed"
FALLBACK_ENTRY = "Internal maintenance and stability work."

CHANGELOG_HEADER = "# Changelog\n\nGenerated from the commit history on every release.\n"


def log(message):
    print("release-notes %s" % message, flush=True)


def fail(message):
    print("release-notes status=fail reason=%s" % message, file=sys.stderr, flush=True)
    sys.exit(1)


def git(*arguments):
    result = subprocess.run(["git"] + list(arguments), capture_output=True, text=True)
    if result.returncode != 0:
        fail("git_failed command=%s detail=%s" % (" ".join(arguments), result.stderr.strip()))
    return result.stdout.strip()


def classify(kind, breaking, body):
    lowered = kind.lower()
    if breaking or "BREAKING CHANGE" in body:
        return "breaking"
    if lowered in INTERNAL_KINDS:
        return None
    if lowered in {"feat", "feature"}:
        return "added"
    if lowered in {"fix", "bugfix", "hotfix"}:
        return "fixed"
    return "changed"


def humanize(value):
    cleaned = value.replace("-", " ").replace("_", " ").strip()
    if not cleaned:
        return ""
    return cleaned[:1].upper() + cleaned[1:]


def entry_text(kind, scope, subject):
    label = scope if scope else ("" if kind.lower() in TYPED_KINDS else kind)
    text = subject.strip().rstrip(".")
    if text:
        text = text[:1].upper() + text[1:]
    if label:
        return "**%s** — %s" % (humanize(label), text)
    return text


def collect(revision_range):
    template = FIELD.join(["%H", "%s", "%b"]) + RECORD
    raw = git("log", "--no-merges", "--format=" + template, revision_range)
    commits = []
    for record in raw.split(RECORD):
        if not record.strip():
            continue
        parts = record.lstrip("\n").split(FIELD)
        if len(parts) < 3:
            continue
        commits.append((parts[0], parts[1], parts[2]))
    return commits


def group_commits(commits, label):
    groups = {key: [] for key, _ in GROUP_ORDER}
    internal = 0
    unparsed = 0
    for _, subject, body in commits:
        match = SUBJECT_PATTERN.match(subject)
        if match is None:
            unparsed += 1
            continue
        bucket = classify(match.group("kind"), match.group("bang") == "!", body)
        if bucket is None:
            internal += 1
            continue
        groups[bucket].append(
            entry_text(match.group("kind"), match.group("scope") or "", match.group("subject"))
        )
    kept = sum(len(items) for items in groups.values())
    log(
        "grouped section=%s commits=%d kept=%d internal=%d unparsed=%d"
        % (label, len(commits), kept, internal, unparsed)
    )
    return groups


def render(groups, heading=""):
    lines = []
    if heading:
        lines.append(heading)
    written = 0
    for key, title in GROUP_ORDER:
        items = groups[key]
        if not items:
            continue
        if lines:
            lines.append("")
        lines.append("### %s" % title)
        for item in items:
            lines.append("- %s" % item)
        written += len(items)
    if written == 0:
        if lines:
            lines.append("")
        lines.append("### %s" % dict(GROUP_ORDER)[FALLBACK_GROUP])
        lines.append("- %s" % FALLBACK_ENTRY)
    return "\n".join(lines) + "\n"


def all_tags():
    raw = git("tag", "--list", "v*", "--sort=-creatordate")
    return [line.strip() for line in raw.splitlines() if line.strip()]


def revision_range(previous, head):
    return "%s..%s" % (previous, head) if previous else head


def section_heading(version, date):
    return "## %s — %s" % (version, date)


def build_changelog(version, today, head, tags, previous, pending):
    sections = []
    if pending:
        sections.append(
            render(
                group_commits(collect(revision_range(previous, head)), version),
                section_heading(version, today),
            )
        )
    for index, tag in enumerate(tags):
        older = tags[index + 1] if index + 1 < len(tags) else ""
        date = git("log", "-1", "--format=%cs", tag)
        sections.append(
            render(
                group_commits(collect(revision_range(older, tag)), tag),
                section_heading(tag.lstrip("v"), date),
            )
        )
    return CHANGELOG_HEADER + "\n" + "\n".join(sections)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--notes", default="")
    parser.add_argument("--changelog", default="")
    parser.add_argument("--github-output", default="")
    args = parser.parse_args()

    current_tag = "v%s" % args.version
    tags = all_tags()
    pending = current_tag not in tags
    previous = next((tag for tag in tags if tag != current_tag), "")
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    log(
        "range previous=%s head=%s tags=%d pending=%s"
        % (previous or "none", args.head, len(tags), str(pending).lower())
    )

    if args.notes:
        commits = collect(revision_range(previous, args.head))
        body = render(group_commits(commits, args.version))
        with open(args.notes, "w", encoding="utf-8") as handle:
            handle.write(body)
        log("notes written path=%s bytes=%d" % (args.notes, len(body.encode("utf-8"))))

    if args.changelog:
        document = build_changelog(args.version, today, args.head, tags, previous, pending)
        with open(args.changelog, "w", encoding="utf-8") as handle:
            handle.write(document)
        log(
            "changelog written path=%s sections=%d bytes=%d"
            % (args.changelog, len(tags) + (1 if pending else 0), len(document.encode("utf-8")))
        )

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write("previous=%s\n" % previous)
        log("outputs written previous=%s" % (previous or "none"))


if __name__ == "__main__":
    main()
