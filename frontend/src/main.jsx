import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import PolicyList from './PolicyList.jsx';
import PolicyDetail from './PolicyDetail.jsx';
import './styles.css';

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <header className="app-header">
        <strong>Suraksha Life</strong> <span>Policy Servicing</span>
      </header>
      <main className="app-main">
        <Routes>
          <Route path="/" element={<PolicyList />} />
          <Route path="/policies/:id" element={<PolicyDetail />} />
        </Routes>
      </main>
    </BrowserRouter>
  </React.StrictMode>
);
