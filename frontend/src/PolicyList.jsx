import React, { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { request, loadErrorMessage } from './api.js';
import { formatDate, formatINR, modeLabel } from './format.js';
import StatusBadge, { STATUS_OPTIONS } from './StatusBadge.jsx';

const PAGE_SIZE = 20;

/**
 * Policy list. Filter, search and page live in the URL, so Back and refresh
 * keep the clerk's place. Filtering and paging happen in the database: this
 * screen only ever fetches one page.
 */
export default function PolicyList() {
  const [params, setParams] = useSearchParams();
  const status = params.get('status') || '';
  const search = params.get('search') || '';
  const page = Math.max(1, Number(params.get('page')) || 1);

  const [searchInput, setSearchInput] = useState(search);
  const [state, setState] = useState({ loading: true, error: null, data: null });
  const [retry, setRetry] = useState(0);

  function updateParams(changes, replace = false) {
    setParams((prev) => {
      const next = new URLSearchParams(prev);
      Object.entries(changes).forEach(([key, value]) => {
        if (value === null || value === '') next.delete(key);
        else next.set(key, String(value));
      });
      return next;
    }, { replace });
  }

  // Keep the box in step when the URL changes (Back button, Clear filters).
  useEffect(() => {
    setSearchInput(search);
  }, [search]);

  // Search 300 ms after the clerk stops typing, back to page 1.
  useEffect(() => {
    const text = searchInput.trim();
    if (text === search) return undefined;
    const timer = setTimeout(() => updateParams({ search: text, page: null }, true), 300);
    return () => clearTimeout(timer);
  }, [searchInput, search]);

  useEffect(() => {
    // Abort the previous request so a slow old answer can't overwrite a newer one.
    const controller = new AbortController();
    setState((s) => ({ ...s, loading: true, error: null }));

    const query = new URLSearchParams({ page: String(page), pageSize: String(PAGE_SIZE) });
    if (status) query.set('status', status);
    if (search) query.set('search', search);

    request(`/policies?${query}`, { signal: controller.signal })
      .then(({ data }) => setState({ loading: false, error: null, data }))
      .catch((err) => {
        if (err.name !== 'AbortError') setState({ loading: false, error: err, data: null });
      });
    return () => controller.abort();
  }, [status, search, page, retry]);

  const { loading, error, data } = state;
  const filtered = Boolean(status || search);

  function clearFilters() {
    setSearchInput('');
    updateParams({ status: null, search: null, page: null });
  }

  return (
    <div>
      <div className="page-head">
        <h1>Policies</h1>
        {data && <p className="muted">{data.total} {data.total === 1 ? 'policy' : 'policies'}</p>}
      </div>

      <form
        className="filters"
        role="search"
        onSubmit={(e) => {
          e.preventDefault();
          updateParams({ search: searchInput.trim(), page: null });
        }}
      >
        <label className="field">
          <span>Search</span>
          <input
            type="search"
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
            placeholder="Policy number or customer name"
            maxLength={60}
          />
        </label>
        <label className="field">
          <span>Status</span>
          <select value={status} onChange={(e) => updateParams({ status: e.target.value, page: null })}>
            <option value="">All statuses</option>
            {STATUS_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </select>
        </label>
        {filtered && (
          <button type="button" className="button-link" onClick={clearFilters}>Clear filters</button>
        )}
      </form>

      {error && (
        <div className="state state-error" role="alert">
          <p>Policies could not be loaded. {loadErrorMessage(error)}</p>
          <button type="button" onClick={() => setRetry((n) => n + 1)}>Try again</button>
        </div>
      )}

      {!error && !data && loading && <p className="state" role="status">Loading policies…</p>}

      {!error && data && data.items.length === 0 && (
        <div className="state">
          {data.total === 0 ? (
            <>
              <p>{filtered ? 'No policies match these filters.' : 'There are no policies.'}</p>
              {filtered && <button type="button" onClick={clearFilters}>Clear filters</button>}
            </>
          ) : (
            <>
              <p>This page is empty.</p>
              <button type="button" onClick={() => updateParams({ page: null })}>Go to first page</button>
            </>
          )}
        </div>
      )}

      {!error && data && data.items.length > 0 && (
        <>
          <div className={`table-wrap${loading ? ' is-loading' : ''}`} aria-busy={loading}>
            <table>
              <thead>
                <tr>
                  <th scope="col">Policy no</th>
                  <th scope="col">Status</th>
                  <th scope="col">Customer</th>
                  <th scope="col">Plan</th>
                  <th scope="col">Mode</th>
                  <th scope="col" className="num">Premium</th>
                  <th scope="col">Next due</th>
                </tr>
              </thead>
              <tbody>
                {data.items.map((p) => (
                  <tr key={p.id}>
                    <td><Link to={`/policies/${p.id}`}>{p.policyNo}</Link></td>
                    <td><StatusBadge status={p.status} /></td>
                    <td>{p.customerName || <span className="muted">Customer record missing</span>}</td>
                    <td>{p.planName}</td>
                    <td>{modeLabel(p.mode)}</td>
                    <td className="num">{formatINR(p.premium)}</td>
                    <td>{formatDate(p.nextDueDate)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <nav className="pager" aria-label="Pages">
            <button type="button" disabled={page <= 1 || loading} onClick={() => updateParams({ page: page - 1 })}>
              ← Previous
            </button>
            <span>Page {page} of {data.totalPages}</span>
            <button type="button" disabled={page >= data.totalPages || loading} onClick={() => updateParams({ page: page + 1 })}>
              Next →
            </button>
          </nav>
        </>
      )}
    </div>
  );
}
