import assert from "node:assert/strict";
import test from "node:test";
import { finderHelpMenu } from "./finder-menu.mjs";

const open = `0 Ajuda, Secondary Actions: Cancel, Pick
\t1 menu Secondary Actions: Cancel
\t\t2 searchFieldAction:
\t\t\t3 campo de texto de busca (settable)
\t\t\t4 tabela resultado da busca
\t\t5 Manual de Uso do Mac
\t\t6 Dicas para o Seu Mac`;
const closed = `20 menu bar
\t21 Finder
\t22 Arquivo
\t29 Ajuda`;

test("the observed open Help tree uses Cancel from its declaring element", () => {
    assert.deepEqual(finderHelpMenu(open), { state: "open", index: "0", action: "Cancel" });
    assert.deepEqual(finderHelpMenu(open.replace("Ajuda", "Help")), { state: "open", index: "0", action: "Cancel" });
});
test("a fresh closed menu-bar tree provides its own index after preparation", () => {
    assert.deepEqual(finderHelpMenu(closed), { state: "closed", index: "29" });
    assert.equal(finderHelpMenu(open).state, "open"); // Unchanged observation is not successful preparation.
});
test("missing, ambiguous or unadvertised actions stop rather than guess", () => {
    for (const text of ["0 Finder", `${closed}\n30 Help`, open.replace("Cancel, Pick", "Pick"), "0 Ajuda"])
        assert.throws(() => finderHelpMenu(text), /Unsupported/);
});
