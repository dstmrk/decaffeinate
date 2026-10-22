---
name: decision-ledger
description: Use when closing out a task and handing work back to the user — writing the PR title or description, summarizing what was built, auditing the decisions taken where the prompt or the spec was silent, or reporting the size/cost of a change. Covers the squash merge (the PR title becomes the commit subject with a conventional-commit prefix in Italian, the body is written at ~70 columns because GitHub rewraps it, both finished before the merge), the choices ledger (what counts as a decision, entry format, verdict and confidence, least-confident first, an empty ledger on substantial work is a symptom), filing a leftover finding as a GitHub issue, and the mandatory cost table (production code, comments, selftest, docs, plus new structural surfaces). CLAUDE.md regola 8.
---

# decision-ledger — consegna le decisioni, non il diff

Leggere il diff riga per riga non regge il ritmo con cui il codice viene
prodotto, e una review che non regge il ritmo diventa una firma. Si
sposta la review sull'oggetto dove il giudizio umano decide davvero: le
decisioni. Questa skill descrive l'artefatto di fine task. È un **audit
puro**: non modifica codice.

## Cos'è una decisione

Una scelta fatta **dove il prompt, la spec o `CLAUDE.md` tacevano**, e
che l'utente potrebbe voler ribaltare. In quest'app, per esempio:

- una soglia inventata: intervallo di polling, cutoff di batteria o
  termico, finestra di assestamento prima di campionare il consumo;
- cosa succede al Mac in uno stato non previsto (coperchio chiuso +
  display esterno, schermo bloccato, crash a metà transizione);
- un nuovo comando in `pmsetCmds`, cioè un allargamento del sudoers;
- una chiave `UserDefaults` o una voce di menu nuova (diventa contratto
  con le installazioni esistenti);
- **una cosa che hai deciso di NON fare** quando qualcuno potrebbe
  aspettarsela in questa PR;
- una divergenza consapevole da upstream (Pilot Light) o da una
  convenzione del repo.

Non sono decisioni: naming interno, formattazione, e tutto ciò che una
regola di `CLAUDE.md` già impone.

## Formato di una voce

Ogni voce si legge da sola, senza il diff e senza la chat.

```markdown
### <La scelta in una riga>

- **Scenario:** cosa succede all'utente, end-to-end
- **La spec taceva su:** cosa non era specificato
- **Alternativa scartata:** …e perché ha perso
- **Conseguenze:** cosa diventa più costoso da cambiare dopo
- **Verdetto:** solida · da rivedere · serve l'utente — confidence alta/media/bassa
```

## Regole dure

- **"Funziona" non è un verdetto.** La domanda è quale garanzia regge
  il comportamento (un `precondition`, la CI, una verifica manuale
  descritta), non se il build è verde.
- **Dalla meno confidente alla più confidente.** L'attenzione di chi
  legge va spesa dove sei meno sicuro.
- **Un ledger vuoto su un lavoro sostanzioso è un sintomo**: rileggi la
  sessione e ritrova le scelte.
- **L'audit non blocca.** Una voce "serve l'utente" senza risposta non
  ferma la consegna: adotti la scelta provvisoria, la dichiari tale e la
  tieni reversibile.
- **Dichiara cosa non hai potuto verificare** (per esempio: niente
  build locale perché la sessione era su Linux; comportamento a
  coperchio chiuso non provato su un MacBook).

## Il corpo della PR è un messaggio di commit

Con il merge in squash, titolo e corpo della PR diventano il commit su
`main`: storia git, quella a cui porta `git blame`. Quindi:

- **titolo** = soggetto del commit: prefisso conventional-commit, in
  italiano (`fix: …`, `chore: …`, `perf: …`);
- **corpo a ~70 colonne**: GitHub lo rimanda a capo a ~72 e perde
  l'indentazione di continuazione delle liste. Bullet di una riga sola,
  oppure paragrafi con un lead-in in grassetto; tabelle strette;
- **si scrive prima del merge**: dopo è storia immutabile;
- lo squash crea un commit nuovo: per un follow-up si riparte da `main`
  (`git checkout -B <branch> origin/main`), anche con lo stesso nome.

## Un finding diventa un'issue

Una voce "da rivedere" che resta aperta, o un difetto trovato fuori
scope, diventa un'issue GitHub prima di chiudere il task, e la PR la
linka. Prima cerca fra le issue aperte. Il corpo si legge da solo:
**Problema** (scenario concreto, numeri, data), **Fix** (decisa, o
opzioni con la raccomandata), **Test** (edge case da coprire),
**Trigger** (cosa lo rende urgente, se rimandato). Un fix completo porta
`Closes #N` nella PR; uno parziale cita l'issue senza chiuderla.

## La tabella del costo (sempre per ultima)

```bash
git diff --stat origin/main...HEAD
```

|                                    | aggiunte | tolte | netto |
| ---------------------------------- | -------- | ----- | ----- |
| Codice di produzione (no commenti) |          |       |       |
| Commenti                           |          |       |       |
| Selftest                           |          |       |       |
| Doc, CI e config Claude            |          |       |       |

Poi un paragrafo sulle **superfici strutturali** nuove o tolte, quelle
che un conteggio di righe nasconde: un comando nel sudoers, un
LaunchAgent, una chiave `UserDefaults`, una voce di menu, un timer, una
richiesta di rete, un job CI. Una grossa aggiunta netta per un cambio di
comportamento piccolo è un finding da dichiarare, non da seppellire.
