"""
Retrieval-Augmented Generation: chunking, indexing and semantic search over the
internal knowledge base (src/knowledge/*.md).

The default embedder is a deterministic TF-IDF model so retrieval is reproducible in
CI and evaluations. The `Embedder` protocol lets production swap in dense embeddings
(e.g. a hosted embedding model) and a vector database (pgvector) without touching
callers.
"""

from __future__ import annotations

import math
import re
import unicodedata
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

KNOWLEDGE_DIR = Path(__file__).parent / "knowledge"

_STOPWORDS = frozenset(
    """a an and are as at be by for from has have in is it its of on or that the to
    with this these those than then into over under above below not no any all more
    most such can may must should would will per via each other only our your their
    de la el los las y en del para con por que un una se al es""".split()
)


@dataclass(frozen=True)
class Chunk:
    chunk_id: str  # "<doc_id>#<section-slug>", cited by the LLM
    doc_id: str
    title: str
    text: str


@dataclass(frozen=True)
class RetrievedChunk:
    chunk: Chunk
    score: float

    @property
    def chunk_id(self) -> str:
        return self.chunk.chunk_id

    @property
    def doc_id(self) -> str:
        return self.chunk.doc_id


def tokenize(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKD", text.lower())
    ascii_text = normalized.encode("ascii", "ignore").decode()
    return [t for t in re.findall(r"[a-z0-9]+", ascii_text) if t not in _STOPWORDS and len(t) > 1]


def chunk_markdown(doc_id: str, markdown: str) -> list[Chunk]:
    """Split a document by `##` sections; each section becomes a citable chunk."""
    title_match = re.search(r"^# (.+)$", markdown, flags=re.MULTILINE)
    doc_title = title_match.group(1).strip() if title_match else doc_id

    chunks: list[Chunk] = []
    for section in re.split(r"^## ", markdown, flags=re.MULTILINE)[1:]:
        heading, _, body = section.partition("\n")
        slug = re.sub(r"[^a-z0-9]+", "-", heading.lower()).strip("-")
        chunks.append(
            Chunk(
                chunk_id=f"{doc_id}#{slug}",
                doc_id=doc_id,
                title=f"{doc_title} — {heading.strip()}",
                text=body.strip(),
            )
        )
    return chunks


def load_knowledge_base(directory: Path = KNOWLEDGE_DIR) -> list[Chunk]:
    chunks: list[Chunk] = []
    for path in sorted(directory.glob("*.md")):
        chunks.extend(chunk_markdown(path.stem, path.read_text(encoding="utf-8")))
    return chunks


class Embedder(Protocol):
    def fit(self, corpus: list[str]) -> None: ...

    def embed(self, text: str) -> dict[str, float]: ...


class TfidfEmbedder:
    """Sparse TF-IDF vectors, L2-normalized so the dot product equals cosine similarity."""

    def __init__(self) -> None:
        self._idf: dict[str, float] = {}

    def fit(self, corpus: list[str]) -> None:
        doc_freq: Counter[str] = Counter()
        for text in corpus:
            doc_freq.update(set(tokenize(text)))
        n = len(corpus)
        self._idf = {term: math.log((1 + n) / (1 + df)) + 1.0 for term, df in doc_freq.items()}

    def embed(self, text: str) -> dict[str, float]:
        tf = Counter(tokenize(text))
        vector = {t: (1 + math.log(c)) * self._idf[t] for t, c in tf.items() if t in self._idf}
        norm = math.sqrt(sum(v * v for v in vector.values())) or 1.0
        return {t: v / norm for t, v in vector.items()}


class Retriever:
    """In-memory vector index with top-k cosine search."""

    def __init__(self, chunks: list[Chunk], embedder: Embedder | None = None) -> None:
        self._chunks = chunks
        self._embedder = embedder or TfidfEmbedder()
        self._embedder.fit([f"{c.title} {c.text}" for c in chunks])
        self._vectors = [self._embedder.embed(f"{c.title} {c.text}") for c in chunks]

    @classmethod
    def from_knowledge_base(cls, directory: Path = KNOWLEDGE_DIR) -> Retriever:
        return cls(load_knowledge_base(directory))

    def search(self, query: str, k: int = 4, min_score: float = 0.05) -> list[RetrievedChunk]:
        q = self._embedder.embed(query)
        scored = [
            RetrievedChunk(chunk, sum(w * vec.get(t, 0.0) for t, w in q.items()))
            for chunk, vec in zip(self._chunks, self._vectors, strict=True)
        ]
        scored.sort(key=lambda r: r.score, reverse=True)
        return [r for r in scored[:k] if r.score >= min_score]
