#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
from email.utils import format_datetime, parsedate_to_datetime
from datetime import datetime, timezone
from xml.etree import ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

SIGNATURE_PATTERN = re.compile(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"')


def log(message):
    print("appcast %s" % message, flush=True)


def fail(message):
    print("appcast status=fail reason=%s" % message, file=sys.stderr, flush=True)
    sys.exit(1)


def sign_archive(sign_update, archive, private_key_file):
    command = [sign_update, archive]
    stdin_data = None
    if private_key_file == "-":
        stdin_data = os.environ.get("SPARKLE_PRIVATE_KEY", "")
        if not stdin_data.strip():
            fail("private_key_env_empty variable=SPARKLE_PRIVATE_KEY")
        command += ["-f", "-"]
    elif private_key_file:
        command += ["-f", private_key_file]
    result = subprocess.run(command, capture_output=True, text=True, input=stdin_data)
    if result.returncode != 0:
        fail("sign_update_failed detail=%s" % result.stderr.strip())
    match = SIGNATURE_PATTERN.search(result.stdout)
    if not match:
        fail("sign_update_unparsable output=%s" % result.stdout.strip())
    return match.group(1), int(match.group(2))


def load_channel(path, title, link):
    if os.path.exists(path):
        try:
            tree = ET.parse(path)
        except ET.ParseError as error:
            fail("existing_appcast_unparsable detail=%s" % error)
        root = tree.getroot()
        channel = root.find("channel")
        if channel is None:
            fail("existing_appcast_missing_channel")
        log("loaded existing path=%s items=%d" % (path, len(channel.findall("item"))))
        return root, channel

    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = link
    ET.SubElement(channel, "description").text = "Most recent updates to %s" % title
    ET.SubElement(channel, "language").text = "en"
    log("created new path=%s" % path)
    return root, channel


def sparkle_tag(name):
    return "{%s}%s" % (SPARKLE_NS, name)


def item_version(item):
    node = item.find(sparkle_tag("version"))
    return node.text if node is not None else None


def item_short_version(item):
    node = item.find(sparkle_tag("shortVersionString"))
    return node.text if node is not None else None


def item_sort_key(item):
    epoch = datetime.fromtimestamp(0, tz=timezone.utc)
    node = item.find("pubDate")
    published = epoch
    if node is not None and node.text:
        try:
            parsed = parsedate_to_datetime(node.text)
            published = parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            published = epoch
    raw = item_version(item) or ""
    numeric = int(raw) if raw.isdigit() else 0
    return (published, numeric)


def build_item(args, signature, length, published):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.short_version
    ET.SubElement(item, "pubDate").text = format_datetime(published)
    ET.SubElement(item, sparkle_tag("version")).text = args.version
    ET.SubElement(item, sparkle_tag("shortVersionString")).text = args.short_version
    if args.channel != "stable":
        ET.SubElement(item, sparkle_tag("channel")).text = args.channel
    ET.SubElement(item, sparkle_tag("minimumSystemVersion")).text = args.min_system
    if args.release_notes_url:
        ET.SubElement(item, sparkle_tag("releaseNotesLink")).text = args.release_notes_url
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.download_url,
            "length": str(length),
            "type": "application/octet-stream",
            sparkle_tag("edSignature"): signature,
        },
    )
    return item


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--short-version", required=True)
    parser.add_argument("--channel", required=True, choices=["stable", "preview"])
    parser.add_argument("--min-system", default="14.0")
    parser.add_argument("--release-notes-url", default="")
    parser.add_argument("--sign-update", required=True)
    parser.add_argument("--private-key-file", default="")
    parser.add_argument("--title", default="Sukurini")
    parser.add_argument("--feed-url", default="")
    parser.add_argument("--max-items", type=int, default=40)
    args = parser.parse_args()

    if not os.path.exists(args.archive):
        fail("archive_missing path=%s" % args.archive)
    if not os.access(args.sign_update, os.X_OK):
        fail("sign_update_missing path=%s" % args.sign_update)

    signature, length = sign_archive(args.sign_update, args.archive, args.private_key_file)
    log("signed archive=%s bytes=%d" % (os.path.basename(args.archive), length))

    root, channel = load_channel(args.appcast, args.title, args.feed_url)

    replaced = 0
    for existing in channel.findall("item"):
        same_build = item_version(existing) == args.version
        same_release = item_short_version(existing) == args.short_version
        if same_build or same_release:
            channel.remove(existing)
            replaced += 1
    if replaced:
        log("replaced existing short=%s build=%s count=%d" % (args.short_version, args.version, replaced))

    published = datetime.now(timezone.utc)
    channel.append(build_item(args, signature, length, published))

    items = channel.findall("item")
    for existing in items:
        channel.remove(existing)
    items.sort(key=item_sort_key, reverse=True)
    dropped = max(0, len(items) - args.max_items)
    for existing in items[: args.max_items]:
        channel.append(existing)
    if dropped:
        log("trimmed oldest items count=%d limit=%d" % (dropped, args.max_items))

    ET.indent(root, space="  ")
    ET.ElementTree(root).write(args.appcast, encoding="utf-8", xml_declaration=True)
    log(
        "written path=%s version=%s short=%s channel=%s items=%d"
        % (args.appcast, args.version, args.short_version, args.channel, len(channel.findall("item")))
    )


if __name__ == "__main__":
    main()
