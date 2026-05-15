/**
 * Serializes a ProseMirror inline fragment to a small subset of Markdown
 * we support for round-tripping AI rewrites. Recognized marks:
 *   - bold       → **...**
 *   - italic     → *...*
 *   - code       → `...`
 *   - strike     → ~~...~~
 *   - link       → [text](url)
 *
 * Unknown marks (e.g. textColor / backgroundColor / underline) are stripped:
 * the text content is preserved verbatim, but no syntax is emitted. This is
 * intentional — markdown has no portable representation for those, and the
 * AI's reply parser would just drop them anyway.
 *
 * Block-level nodes inside the slice (paragraphs, headings, etc.) are
 * flattened to a trailing "\n" so cross-block selections still yield
 * readable input for the LLM. HardBreaks emit "\n".
 *
 * This is a "lossy but lossless-enough for prose rewrites" serializer — its
 * only consumer is the AI prompt round-trip, not on-disk markdown export.
 *
 * Typed as `any` at this boundary: prosemirror-model isn't a direct
 * dependency of this package (it's pulled in transitively via BlockNote /
 * TipTap), and the rest of the codebase treats PM entities as opaque `any`
 * for the same reason. The runtime shape we rely on is documented in the
 * comments below.
 */

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyPMSlice = any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyPMNode = any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyPMMark = any;

export function inlineFragmentToMarkdown(slice: AnyPMSlice): string {
  let out = "";
  slice.content.forEach((node: AnyPMNode) => {
    out += inlineNodeToMarkdown(node);
  });
  return out;
}

function inlineNodeToMarkdown(node: AnyPMNode): string {
  if (node.isText) {
    const text: string = node.text ?? "";
    const marks: AnyPMMark[] = node.marks ?? [];
    // Code spans don't allow nested formatting in CommonMark, so when the
    // run is `code` we emit backticks directly and ignore any other marks
    // that happen to also be on the node.
    if (marks.find((m) => m.type.name === "code")) {
      return "`" + text + "`";
    }
    // Build inside-out so the rendered nesting matches the mark stack.
    // Order: strike → bold → italic → link. Deterministic regardless of
    // mark-set order on the node, which keeps output stable across runs.
    let wrapped = text;
    if (marks.find((m) => m.type.name === "strike")) {
      wrapped = "~~" + wrapped + "~~";
    }
    if (marks.find((m) => m.type.name === "bold")) {
      wrapped = "**" + wrapped + "**";
    }
    if (marks.find((m) => m.type.name === "italic")) {
      wrapped = "*" + wrapped + "*";
    }
    const link = marks.find((m) => m.type.name === "link");
    if (link) {
      const href = (link.attrs?.href as string | undefined) ?? "";
      wrapped = `[${wrapped}](${href})`;
    }
    return wrapped;
  }
  if (node.type?.name === "hardBreak") {
    return "\n";
  }
  if (node.isBlock) {
    let inner = "";
    node.forEach((child: AnyPMNode) => {
      inner += inlineNodeToMarkdown(child);
    });
    return inner + "\n";
  }
  // Fallback: descend into children for unknown inline wrappers.
  let inner = "";
  node.forEach((child: AnyPMNode) => {
    inner += inlineNodeToMarkdown(child);
  });
  return inner;
}
