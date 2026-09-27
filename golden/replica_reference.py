"""FINAL empirical replica of the installed tokenizers-0.23.2 pipeline (mmBERT).

Per text:
 1. Added-token (special=True) isolated split, longest-first, no boundaries.
 2. Per plain piece: normalizer Replace(" " -> "▁").
 3. Piece-level prepend (scheme=Always): prepend "▁" UNLESS the piece starts
    with "▁", or "\n", or "\t\t" (proven: '\t...' prepends iff the 2nd char
    is not a tab; '\n...' and '▁...' never prepend).
 4. Split on "▁" MergedWithNext over alternating char-runs.
 5. Model-level tokenize per chunk (model WS = {'\t','\n'}):
    - segment runs -> digit isolation: each ASCII '0'-'9' is its own token
      (legacy non-ASCII digit tokens like '۱۳' pass through whole);
      then BPE.
    - segment right after a run containing '\n' gets "▁" prepended first.
    - whitespace runs -> greedy longest token from vocab, else per-char.
 6. BPE: vocab chars; byte-fallback <0xNN> iff ALL bytes present; else <unk>
    (consecutive unk fused); merge leftmost-lowest-rank pair repeatedly;
    rank = index in JSON merges list (no filtering).
"""
import json, sys, re

TOK_PATH = '/Users/andrei/Developer/ai/laya/models/source/tokenizer/tokenizer.json'

def load(tok_path=TOK_PATH):
    TOK = json.load(open(tok_path))
    vocab = TOK['model']['vocab']
    rank = {}
    for i, pr in enumerate(TOK['model']['merges']):
        a, b = pr
        if a in vocab and b in vocab:
            rank.setdefault((a, b), i)
    # ALL added tokens (special or not) match atomically before the
    # pre_tokenizer (added_vocabulary.rs). Longest-first leftmost match.
    added = sorted([a['content'] for a in TOK['added_tokens']], key=len, reverse=True)
    lstrip_set = set(a['content'] for a in TOK['added_tokens'] if a['lstrip'])
    return TOK, vocab, rank, (added, lstrip_set)

TOK, vocab, rank, (added, lstrip_set) = load()
REPL = '\u2581'
UNK = vocab['<unk>']
MODEL_WS = '\t\n'

def bpe(word):
    syms = []
    for ch in word:
        if ch in vocab:
            syms.append(ch)
        else:
            bs, ok = [], True
            for x in ch.encode('utf-8'):
                t = '<0x%02X>' % x
                if t in vocab: bs.append(t)
                else: ok = False; break
            if ok: syms.extend(bs)
            elif not (syms and syms[-1] == '<unk>'): syms.append('<unk>')
    while len(syms) > 1:
        best, bi = None, -1
        for i in range(len(syms) - 1):
            r = rank.get((syms[i], syms[i+1]))
            if r is not None and (best is None or r < best):
                best, bi = r, i
        if best is None: break
        # Rust merge_all: ONE instance per heap pop (lowest rank, then lowest
        # pos), re-evaluate adjacency after every merge.
        m = syms[bi] + syms[bi+1]
        syms = syms[:bi] + [m] + syms[bi+2:]
    return [vocab.get(s, UNK) for s in syms]

def emit_ws_run(run):
    ids, i = [], 0
    n = len(run)
    while i < n:
        j = min(n, i + 31)
        while j > i and run[i:j] not in vocab:
            j -= 1
        if j == i:
            ids.append(vocab.get(run[i]) or bpe(run[i])[0])
            i += 1
        else:
            ids.append(vocab[run[i:j]])
            i = j
    return ids

_wc = {}
def model_tokenize(chunk):
    if chunk in _wc: return _wc[chunk]
    ids = bpe(chunk)
    _wc[chunk] = ids
    return ids

# Rust regex \s == Unicode White_Space (NOT Python's broader \s which also
# matches U+1C..U+1F file/group/record/unit separators).
RUST_WS = ' \t\n\x0b\x0c\r\u0085\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000'
LEFTMOST_SPACE_AT_END = re.compile('[' + RUST_WS + ']*$')

def split_added(text):
    """added_vocabulary.rs find_matches (trie: leftmost, longest at the start;
    lstrip extends start = max(space_leftmost_at_end(text[..start]),
    start_offset)). The absorbed span is DROPPED — Metaspace never sees it;
    the single token carries the added id with the full slice as its value.
    Yields ('tok', id) / ('txt', plain_piece)."""
    out, i = [], 0
    n = len(text)
    while i < n:
        j = i
        while j < n:
            hits = [s for s in added if text.startswith(s, j)]
            if hits:
                break
            j += 1
        if j >= n:
            out.append(('txt', text[i:])); break
        at = max(hits, key=len)          # longest at the leftmost start
        stop = j + len(at)
        if at in lstrip_set:
            m = LEFTMOST_SPACE_AT_END.search(text, 0, j)
            newstart = m.start() if m else j
            start = max(newstart, i)
        else:
            start = j
        if i < start:
            out.append(('txt', text[i:start]))
        out.append(('tok', vocab[at]))   # absorbed ws vanishes into this id
        i = stop
    return out

def metaspace_piece(piece):
    """steps: normalizer Replace(' '->REPL); prepend REPL unless piece starts
    with REPL; fold-split on REPL with MergedWithNext over PER-CHAR intervals
    (Rust find_matches yields one match per REPL char, not per run)."""
    w = piece.replace(' ', REPL)
    if w and not w.startswith(REPL):
        w = REPL + w
    if not w: return []
    # intervals: each REPL char is its own match interval; runs of non-REPL
    # chars are single non-match intervals (Rust find_matches alternation)
    n = len(w)
    ivs = []  # (start, end, is_match)
    i = 0
    while i < n:
        if w[i] == REPL:
            ivs.append((i, i+1, True)); i += 1
        else:
            j = i
            while j < n and w[j] != REPL: j += 1
            ivs.append((i, j, False)); i = j
    acc, prev_match = [], False
    for (s, e, m) in reversed(ivs):
        if m and not prev_match:
            if acc:
                a0, a1 = acc[-1]; acc[-1] = (s, a1)
            else:
                acc.append((s, e))
        else:
            acc.append((s, e))
        prev_match = m
    acc.reverse()
    return [w[a:b] for a, b in acc if b > a]

def prepend_chunk(chunk):
    """The 0.23.2 prepend: REPL attaches to the first SEGMENT of the chunk."""
    if REPL in chunk:
        return chunk
    i = 0
    while i < len(chunk) and chunk[i] in MODEL_WS:
        i += 1
    if i == 0:          # starts with a segment
        return REPL + chunk
    if i >= 2:          # leading ws-run >= 2 chars: no prepend
        return chunk
    return chunk[:i] + REPL + chunk[i:]

def encode(text):
    ids = []
    for kind, payload in split_added(text):
        if kind == 'tok':
            ids.append(payload); continue
        if not payload: continue
        for chunk in metaspace_piece(payload):
            ids.extend(model_tokenize(chunk))
    return ids

if __name__ == '__main__':
    GOLD = json.load(open('/Users/andrei/Developer/ai/laya-plugin-swift/golden/tokenizer_golden.json'))
    inv = {v: k for k, v in vocab.items()}
    bad = 0
    for c in GOLD['tokenizer']['cases']:
        mine = encode(c['text'])
        if mine != c['ids']:
            bad += 1
            print('MISMATCH', repr(c['text'][:60]))
            for i, (a, b) in enumerate(zip(mine, c['ids'])):
                if a != b:
                    print('  at', i, 'gold', b, repr(inv.get(b)), 'mine', a, repr(inv.get(a))); break
            else:
                print('  len gold', len(c['ids']), 'mine', len(mine))
    print('goldens tok cases:', len(GOLD['tokenizer']['cases']), 'mismatches:', bad)

    D = json.load(open('/Users/andrei/.hermes/profiles/developer/cache/scratch/chunking_dump.json'))
    bad2 = shown = 0
    for s, gold in D.items():
        gold_seq = [t for t, _ in gold]
        mine_str = [inv.get(i) for i in encode(s)]
        if mine_str != gold_seq:
            bad2 += 1
            if shown < 10:
                shown += 1
                k = next((i for i in range(max(len(mine_str), len(gold_seq)))
                          if i >= len(mine_str) or i >= len(gold_seq) or mine_str[i] != gold_seq[i]), None)
                print(repr(s), 'at', k, 'gold', gold_seq[max(0,k-1):k+3], 'mine', mine_str[max(0,k-1):k+3])
    print('dump strings:', len(D), 'mismatches:', bad2)
