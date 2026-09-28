// Only the two observed Help-menu shapes; no inferred actions or fallback indices.
export function finderHelpMenu(text) {
    const matches = [...text.matchAll(/^\s*(\d+)\s+(?:Ajuda|Help)(?:,\s*Secondary Actions:\s*([^\r\n]+))?\s*$/gm)];
    if (matches.length !== 1) throw new Error("Unsupported Finder state: expected one unambiguous Help menu element");
    const [, index, declared] = matches[0];
    const actions = declared?.split(",").map(action => action.trim()) ?? [];
    if (actions.includes("Cancel")) return { state: "open", index, action: "Cancel" };
    if (!declared && /^\s*\d+\s+menu bar\s*$/m.test(text)) return { state: "closed", index };
    throw new Error("Unsupported Finder Help state: neither a closed menu-bar entry nor declared Cancel");
}
