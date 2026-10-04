import React, { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { request, loadErrorMessage } from './api.js';
import { formatDate, formatDateTime, formatINR, modeLabel } from './format.js';
import StatusBadge from './StatusBadge.jsx';
import PaymentForm from './PaymentForm.jsx';

/** One sentence telling the clerk what to do with this policy today. */
function CollectSummary({ policy: p }) {
  switch (p.status) {
    case 'NOT_SERVICEABLE':
      return <p>This policy can't take payments at the counter: its record is incomplete (premium, mode or due date missing). Refer the customer to the servicing team.</p>;
    case 'PAID':
      return <p>Nothing to collect today. The next premium of <strong>{formatINR(p.premium)}</strong> is due on <strong>{formatDate(p.nextDueDate)}</strong>.</p>;
    case 'DUE':
      return <p>Premium of <strong>{formatINR(p.amountDue)}</strong> is due on <strong>{formatDate(p.nextDueDate)}</strong>.</p>;
    case 'IN_GRACE':
      return <p>Premium of <strong>{formatINR(p.amountDue)}</strong> was due on {formatDate(p.nextDueDate)}. The grace period ends on <strong>{formatDate(p.graceEndDate)}</strong>: collect now to keep the policy active.</p>;
    case 'LAPSED':
      return p.amountDue === null
        ? <p>This policy has lapsed and could only be revived until <strong>{formatDate(p.revivalDeadline)}</strong>. Payment can't be accepted. Refer the customer to the servicing team.</p>
        : <p>This policy has lapsed. It can be revived until <strong>{formatDate(p.revivalDeadline)}</strong> by paying all {p.instalmentsDue} pending {p.instalmentsDue === 1 ? 'premium' : 'premiums'} at once: {p.instalmentsDue} × {formatINR(p.premium)} = <strong>{formatINR(p.amountDue)}</strong>.</p>;
    default:
      return null;
  }
}

export default function PolicyDetail() {
  const { id } = useParams();
  const navigate = useNavigate();
  const [state, setState] = useState({ loading: true, error: null, data: null });
  const [reload, setReload] = useState(0);
  const [receipt, setReceipt] = useState(null);
  const [notice, setNotice] = useState(null);

  useEffect(() => {
    const controller = new AbortController();
    setState((s) => ({ ...s, loading: true, error: null }));
    request(`/policies/${encodeURIComponent(id)}`, { signal: controller.signal })
      .then(({ data }) => setState({ loading: false, error: null, data }))
      .catch((err) => {
        if (err.name !== 'AbortError') setState({ loading: false, error: err, data: null });
      });
    return () => controller.abort();
  }, [id, reload]);

  // Back to the list with its filters if we came from it, else to the start.
  function goBack() {
    if (window.history.state && window.history.state.idx > 0) navigate(-1);
    else navigate('/');
  }

  const { loading, error, data } = state;
  const back = <button type="button" className="button-link back" onClick={goBack}>← All policies</button>;

  if (error) {
    return (
      <div>
        {back}
        {error.status === 404 || error.status === 400 ? (
          <div className="state">
            <h1>Policy not found</h1>
            <p>There is no policy with id {id}.</p>
            <Link to="/">Go to the policy list</Link>
          </div>
        ) : (
          <div className="state state-error" role="alert">
            <p>The policy could not be loaded. {loadErrorMessage(error)}</p>
            <button type="button" onClick={() => setReload((n) => n + 1)}>Try again</button>
          </div>
        )}
      </div>
    );
  }

  if (!data) {
    return <div>{back}<p className="state" role="status">Loading policy…</p></div>;
  }

  const { policy: p, customer: c, payments } = data;
  const canPay = p.amountDue !== null && p.amountDue > 0;

  return (
    <div aria-busy={loading}>
      {back}

      <div className="page-head">
        <h1>Policy {p.policyNo}</h1>
        <StatusBadge status={p.status} />
      </div>

      {receipt && (
        <div className="notice notice-success" role="status">
          <strong>
            {receipt.result === 'ALREADY_RECORDED'
              ? 'This payment was already recorded. The customer was not charged again.'
              : 'Payment recorded.'}
          </strong>{' '}
          Receipt no. {receipt.paymentId} · {formatINR(receipt.amount)}
          {receipt.nextDueDate && <> · next premium due {formatDate(receipt.nextDueDate)}</>}
        </div>
      )}
      {notice && <div className="notice notice-warning" role="alert">{notice}</div>}

      <section className="panel collect">
        <CollectSummary policy={p} />
      </section>

      <div className="columns">
        <section className="panel">
          <h2>Policy</h2>
          <dl className="details">
            <dt>Plan</dt><dd>{p.planName}</dd>
            <dt>Premium</dt><dd>{formatINR(p.premium)} {p.mode && <span className="muted">({modeLabel(p.mode)})</span>}</dd>
            <dt>Sum assured</dt><dd>{formatINR(p.sumAssured)}</dd>
            <dt>Start date</dt><dd>{formatDate(p.commencementDate)}</dd>
            <dt>Next due</dt><dd>{formatDate(p.nextDueDate)}</dd>
            <dt>Grace ends</dt><dd>{formatDate(p.graceEndDate)}</dd>
            {p.status === 'LAPSED' && (
              <>
                <dt>First unpaid</dt><dd>{formatDate(p.firstUnpaidDueDate)}</dd>
                <dt>Revive by</dt><dd>{formatDate(p.revivalDeadline)}</dd>
              </>
            )}
          </dl>
        </section>

        <section className="panel">
          <h2>Customer</h2>
          {c ? (
            <dl className="details">
              <dt>Name</dt><dd>{c.name}</dd>
              <dt>PAN</dt><dd>{c.pan}</dd>
              <dt>Mobile</dt><dd>{c.mobile}</dd>
              <dt>Email</dt><dd>{c.email}</dd>
              <dt>City</dt><dd>{c.city}</dd>
            </dl>
          ) : (
            <p className="muted">Customer record missing. Refer to the servicing team to fix it.</p>
          )}
        </section>
      </div>

      {canPay && (
        <section className="panel">
          <PaymentForm
            key={p.nextDueDate}
            policy={p}
            onRecorded={(result) => {
              setNotice(null);
              setReceipt(result);
              setReload((n) => n + 1);
            }}
            onStale={(message) => {
              setReceipt(null);
              setNotice(message);
              setReload((n) => n + 1);
            }}
          />
        </section>
      )}

      <section className="panel">
        <h2>Payment history</h2>
        {payments.length === 0 ? (
          <p className="muted">No payments recorded for this policy.</p>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th scope="col">Paid on (IST)</th>
                  <th scope="col" className="num">Amount</th>
                  <th scope="col">For premium due</th>
                  <th scope="col">Paid by</th>
                  <th scope="col">Receipt no.</th>
                </tr>
              </thead>
              <tbody>
                {payments.map((y) => (
                  <tr key={y.id}>
                    <td>
                      {formatDateTime(y.paidAt)}
                      {y.paidLate && <span className="tag-late" title="Paid after the grace period of that premium"> · paid late</span>}
                    </td>
                    <td className="num">{formatINR(y.amount)}</td>
                    <td>
                      {formatDate(y.coversDueDate)}
                      {y.instalments > 1 && <span className="muted"> ({y.instalments} premiums)</span>}
                    </td>
                    <td>{y.channel}</td>
                    <td>{y.id}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
