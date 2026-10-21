"""RAG retrieval: chunking, ranking and determinism."""

from src.retrieval import Retriever, chunk_markdown, load_knowledge_base, tokenize


def test_chunks_are_citable_sections():
    chunks = chunk_markdown("doc", "# Title\n\n## First Part\nalpha beta\n\n## Second\ngamma")
    assert [c.chunk_id for c in chunks] == ["doc#first-part", "doc#second"]
    assert chunks[0].title == "Title — First Part"


def test_tokenize_normalizes_accents_and_stopwords():
    assert tokenize("La Política de Inversión y the BONDS") == ["politica", "inversion", "bonds"]


def test_knowledge_base_loads_all_documents():
    doc_ids = {c.doc_id for c in load_knowledge_base()}
    assert {"investment_policy", "suitability_and_oversight", "crypto_volatility"} <= doc_ids


def test_relevant_document_ranks_first():
    retriever = Retriever.from_knowledge_base()
    top = retriever.search("crypto volatility drawdown exposure cap", k=3)
    assert top[0].doc_id == "crypto_volatility"

    top = retriever.search("single stock concentration diversification", k=3)
    assert top[0].doc_id == "equity_concentration_risk"


def test_search_is_deterministic_and_respects_k():
    retriever = Retriever.from_knowledge_base()
    first = [r.chunk_id for r in retriever.search("bond interest rates", k=2)]
    second = [r.chunk_id for r in retriever.search("bond interest rates", k=2)]
    assert first == second and len(first) == 2


def test_irrelevant_query_returns_nothing():
    assert Retriever.from_knowledge_base().search("xylophone zebra quantum") == []
