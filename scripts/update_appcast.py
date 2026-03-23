#!/usr/bin/env python3

import argparse
import os
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def qname(namespace: str, tag: str) -> str:
    return f"{{{namespace}}}{tag}"


def ensure_channel(root: ET.Element) -> ET.Element:
    channel = root.find("channel")
    if channel is None:
        channel = ET.SubElement(root, "channel")

    fields = {
        "title": "TypeWhisper Updates",
        "language": "en",
        "description": "Stable, release candidate, and daily updates for TypeWhisper.",
    }
    for tag, value in fields.items():
        element = channel.find(tag)
        if element is None:
            element = ET.SubElement(channel, tag)
        element.text = value

    return channel


def channel_key(item: ET.Element) -> str:
    channel = item.find(qname(SPARKLE_NS, "channel"))
    return channel.text if channel is not None and channel.text else "stable"


def sort_key(item: ET.Element) -> tuple[int, str]:
    version = item.findtext(qname(SPARKLE_NS, "version"), default="0")
    try:
        numeric = int(version)
    except ValueError:
        numeric = 0
    return (-numeric, channel_key(item))


def build_item(args: argparse.Namespace) -> ET.Element:
    item = ET.Element("item")

    title = ET.SubElement(item, "title")
    title.text = args.title

    pub_date = ET.SubElement(item, "pubDate")
    pub_date.text = args.pub_date

    sparkle_version = ET.SubElement(item, qname(SPARKLE_NS, "version"))
    sparkle_version.text = args.build_version

    short_version = ET.SubElement(item, qname(SPARKLE_NS, "shortVersionString"))
    short_version.text = args.version

    minimum_system_version = ET.SubElement(item, qname(SPARKLE_NS, "minimumSystemVersion"))
    minimum_system_version.text = args.minimum_system_version

    if args.channel != "stable":
        sparkle_channel = ET.SubElement(item, qname(SPARKLE_NS, "channel"))
        sparkle_channel.text = args.channel

    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.url,
            qname(SPARKLE_NS, "edSignature"): args.signature,
            "length": args.length,
            "type": "application/octet-stream",
        },
    )

    return item


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--channel", required=True, choices=["stable", "release-candidate", "daily"])
    parser.add_argument("--title", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--pub-date", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--minimum-system-version", default="15.0")
    args = parser.parse_args()

    appcast_path = Path(args.appcast)
    if appcast_path.exists():
        tree = ET.parse(appcast_path)
        root = tree.getroot()
    else:
        root = ET.Element("rss", {"version": "2.0"})
        tree = ET.ElementTree(root)

    channel = ensure_channel(root)

    for item in list(channel.findall("item")):
        if channel_key(item) == args.channel:
            channel.remove(item)

    channel.append(build_item(args))

    items = sorted(channel.findall("item"), key=sort_key)
    for item in list(channel.findall("item")):
        channel.remove(item)
    for item in items:
        channel.append(item)

    ET.indent(tree, space="  ")
    appcast_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
