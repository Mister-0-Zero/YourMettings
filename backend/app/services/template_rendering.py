"""Constrained model output -> mobile Markdown, with server-owned heading positions."""
import re


def navigation(content):
    result, fenced = [], False
    for line_index, line in enumerate(content.splitlines()):
        if re.match(r"^\s*(`{3,}|~{3,})", line):
            fenced = not fenced
        match = None if fenced else re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        if match:
            result.append({"id": f"ym-h-{len(result)}", "title": match[2],
                "level": len(match[1]), "heading_index": len(result), "line_index": line_index})
    return result


def output_schema(template):
    def parts(sections):
        properties = {}
        for section in sections:
            if section["type"] == "repeated":
                properties[section["id"]] = {"type": "array", "maxItems": 40, "items": {
                    "type": "object", "properties": {"title": {"type": "string"},
                        "sections": parts(section["children"])}, "required": ["title", "sections"],
                    "additionalProperties": False}}
            else:
                properties[section["id"]] = {"type": "string"}
        return {"type": "object", "properties": properties,
            "required": [s["id"] for s in sections if s["required"]], "additionalProperties": False}
    properties = {"sections": parts(template["sections"])}
    if template["structure_mode"] == "flexible":
        properties["extra_sections"] = {"type": "array", "maxItems": 10, "items": {
            "type": "object", "properties": {"title": {"type": "string"}, "content": {"type": "string"}},
            "required": ["title", "content"], "additionalProperties": False}}
    return {"type": "object", "properties": properties, "required": ["sections"], "additionalProperties": False}


def _title(value):
    if not isinstance(value, str) or len(value) > 400:
        raise ValueError("Invalid heading")
    value = re.sub(r"[\r\n\t<>#\[\]()]", " ", value).strip()
    return " ".join(value.split()) or "Не указано"


def _text(value):
    if not isinstance(value, str) or len(value) > 150_000:
        raise ValueError("Invalid section text")
    # Model cannot introduce document headings, HTML, links or wide tables via body text.
    lines = []
    for line in value.strip().splitlines():
        line = re.sub(r"^\s{0,3}#{1,6}\s*", "", line)
        line = re.sub(r"<[^>]*>", "", line)
        line = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", line)
        line = line.replace("|", " / ").replace("```", "").replace("~~~", "")
        # Setext headings and horizontal rules can otherwise create extra headings.
        if re.fullmatch(r"\s*[-=]+\s*", line):
            continue
        # Escaping after every transform also handles nested/quoted/list ATX headings.
        line = re.sub(r"(?<!\\)#", r"\\#", line)
        lines.append(line)
    result = "\n".join(lines).strip()
    if not result or re.fullmatch(r"не\s+указано[.!]?", result, flags=re.IGNORECASE):
        return "Не указано"
    return result


def render_document(data, template):
    if not isinstance(data, dict) or set(data) - {"sections", "extra_sections"}:
        raise ValueError("Invalid document")
    sections = data.get("sections")
    if not isinstance(sections, dict):
        raise ValueError("Missing sections")
    known = {s["id"] for s in template["sections"]}
    if set(sections) - known:
        raise ValueError("Unknown section")
    lines, contents_range = [], None
    for spec in template["sections"]:
        key = spec["id"]
        if key not in sections and not spec["required"]:
            continue
        lines += ["## " + _title(spec["title"]), ""]
        if spec["type"] == "repeated":
            topics = sections.get(key, [])
            if not isinstance(topics, list) or len(topics) > 40:
                raise ValueError("Invalid repeated block")
            if not topics:
                lines += ["Не указано", ""]
            for topic in topics:
                if not isinstance(topic, dict) or set(topic) != {"title", "sections"}:
                    raise ValueError("Invalid topic")
                title = _title(topic["title"])
                lines += ["### " + title, ""]
                children = topic["sections"]
                if not isinstance(children, dict) or set(children) - {c["id"] for c in spec["children"]}:
                    raise ValueError("Unknown subsection")
                for child in spec["children"]:
                    if child["id"] in children or child["required"]:
                        lines += ["#### " + _title(child["title"]), "", _text(children.get(child["id"], "")), ""]
        else:
            start = len(lines)
            lines += [_text(sections.get(key, "")), ""]
            # Only the immutable universal template has a server-built contents section.
            if template.get("is_system") and template.get("is_default") and spec["title"] == "Содержание":
                contents_range = (start, len(lines))
    extras = data.get("extra_sections", [])
    if not isinstance(extras, list) or len(extras) > 10:
        raise ValueError("Invalid extra sections")
    if template["structure_mode"] == "strict" and extras:
        raise ValueError("Extra sections in strict document")
    for extra in extras:
        if not isinstance(extra, dict) or set(extra) != {"title", "content"}:
            raise ValueError("Invalid extra section")
        lines += ["## " + _title(extra["title"]), "", _text(extra["content"]), ""]
    if contents_range:
        # Anchor IDs depend only on heading ordinal, never on title spelling or uniqueness.
        headings = navigation("\n".join(lines))
        links = [f"- [{h['title']}](#{h['id']})" for h in headings if h["level"] == 3]
        a, b = contents_range
        lines[a:b] = links + [""] if links else ["Не указано", ""]
    return "\n".join(lines).strip()
