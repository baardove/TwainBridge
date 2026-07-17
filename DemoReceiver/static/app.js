const state = { documents: [], filter: "all", search: "", sort: "newest", activeId: null, zoom: 1, loaded: false };
const $ = (selector) => document.querySelector(selector);
const grid = $("#documentGrid");
const viewer = $("#viewer");
let toastTimer;

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (char) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[char]));
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes < 1) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const order = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  return `${(bytes / 1024 ** order).toFixed(order ? 1 : 0)} ${units[order]}`;
}

function formatDate(value, short = false) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Unknown";
  return new Intl.DateTimeFormat(undefined, short
    ? { month: "short", day: "numeric" }
    : { dateStyle: "medium", timeStyle: "short" }).format(date);
}

function endpoint() { return `${window.location.origin}/upload`; }
function showToast(message) {
  const toast = $("#toast");
  toast.textContent = message;
  toast.classList.add("visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove("visible"), 2400);
}

async function copyEndpoint() {
  try { await navigator.clipboard.writeText(endpoint()); showToast("Upload endpoint copied"); }
  catch { showToast(endpoint()); }
}

function visibleDocuments() {
  const term = state.search.trim().toLocaleLowerCase();
  const filtered = state.documents.filter((document) => {
    const matchesType = state.filter === "all" || document.kind === state.filter;
    const haystack = `${document.filename} ${document.source || ""} ${document.document_id || ""}`.toLocaleLowerCase();
    return matchesType && (!term || haystack.includes(term));
  });
  return filtered.sort((left, right) => {
    if (state.sort === "name") return left.filename.localeCompare(right.filename);
    const delta = new Date(left.received_at) - new Date(right.received_at);
    return state.sort === "oldest" ? delta : -delta;
  });
}

function cardMarkup(document, index) {
  const preview = document.kind === "image"
    ? `<img src="${escapeHtml(document.file_url)}" alt="" loading="lazy">`
    : `<span class="pdf-sheet" aria-hidden="true"><i></i><i></i><i></i></span>`;
  const secondary = document.source || `${document.page_count || 1} page${document.page_count === 1 ? "" : "s"} · ${formatBytes(document.size)}`;
  return `<button class="document-card" type="button" data-id="${document.id}" style="--index:${index}" aria-label="Open ${escapeHtml(document.filename)}">
    <span class="card-preview">${preview}<span class="type-badge">${document.kind === "pdf" ? "PDF" : "Image"}</span></span>
    <span class="card-meta"><span><strong>${escapeHtml(document.filename)}</strong><p>${escapeHtml(secondary)}</p></span><time datetime="${escapeHtml(document.received_at)}">${formatDate(document.received_at, true)}</time></span>
  </button>`;
}

function render() {
  const visible = visibleDocuments();
  grid.innerHTML = visible.map(cardMarkup).join("");
  const trulyEmpty = state.documents.length === 0;
  $("#emptyState").hidden = !trulyEmpty;
  grid.hidden = trulyEmpty;
  if (!trulyEmpty && visible.length === 0) {
    grid.innerHTML = `<p class="empty-results">No documents match these filters.</p>`;
  }
  const totalBytes = state.documents.reduce((sum, item) => sum + (item.size || 0), 0);
  $("#librarySummary").textContent = `${state.documents.length} item${state.documents.length === 1 ? "" : "s"} · ${formatBytes(totalBytes)}`;
}

async function loadDocuments({quiet = false} = {}) {
  try {
    const response = await fetch("/api/documents", {cache: "no-store"});
    if (!response.ok) throw new Error(`Receiver returned ${response.status}`);
    const payload = await response.json();
    const previousCount = state.documents.length;
    const nextDocuments = payload.documents || [];
    const libraryChanged = !state.loaded || JSON.stringify(nextDocuments) !== JSON.stringify(state.documents);
    state.documents = nextDocuments;
    state.loaded = true;
    $("#errorBanner").hidden = true;
    $(".receiver-status").classList.add("online");
    $("#connectionLabel").textContent = "Receiver online";
    if (libraryChanged) render();
    if (quiet && state.documents.length > previousCount) showToast("A new document arrived");
    openFromHash();
  } catch (error) {
    $(".receiver-status").classList.remove("online");
    $("#connectionLabel").textContent = "Receiver unavailable";
    $("#librarySummary").textContent = "Connection lost";
    const banner = $("#errorBanner");
    banner.textContent = `Could not refresh the library: ${error.message}`;
    banner.hidden = false;
  }
}

function setZoom(value) {
  state.zoom = Math.min(3, Math.max(.5, value));
  $("#imagePreview").style.setProperty("--zoom", state.zoom);
  $("#zoomReset").textContent = `${Math.round(state.zoom * 100)}%`;
}

function activeDocument() { return state.documents.find((item) => item.id === state.activeId); }
function openViewer(id, updateHash = true) {
  const document = state.documents.find((item) => item.id === id);
  if (!document) return;
  state.activeId = id;
  setZoom(1);
  $("#viewerTitle").textContent = document.filename;
  $("#viewerKind").textContent = document.kind === "pdf" ? "PDF document" : "Image capture";
  const image = $("#imagePreview");
  const pdf = $("#pdfPreview");
  const isImage = document.kind === "image";
  image.hidden = !isImage; pdf.hidden = isImage; $("#imageTools").hidden = !isImage;
  if (isImage) { image.src = document.file_url; image.alt = `Preview of ${document.filename}`; pdf.src = "about:blank"; }
  else { pdf.src = document.file_url; image.removeAttribute("src"); }
  $("#downloadDocument").href = document.download_url;
  $("#downloadDocument").setAttribute("download", document.filename);
  $("#openDocument").href = document.file_url;
  $("#detailReceived").textContent = formatDate(document.received_at);
  $("#detailSource").textContent = document.source || "Not provided";
  $("#detailPages").textContent = document.page_count || 1;
  $("#detailSize").textContent = formatBytes(document.size);
  $("#detailId").textContent = document.document_id || document.id;
  const index = state.documents.findIndex((item) => item.id === id);
  $("#viewerPosition").textContent = `${index + 1} / ${state.documents.length}`;
  $("#previousDocument").disabled = state.documents.length < 2;
  $("#nextDocument").disabled = state.documents.length < 2;
  if (!viewer.open) viewer.showModal();
  if (updateHash) history.replaceState(null, "", `#document=${encodeURIComponent(id)}`);
}

function moveViewer(offset) {
  const index = state.documents.findIndex((item) => item.id === state.activeId);
  if (index < 0 || state.documents.length < 2) return;
  const next = (index + offset + state.documents.length) % state.documents.length;
  openViewer(state.documents[next].id);
}

function closeViewer() {
  if (viewer.open) viewer.close();
  state.activeId = null;
  history.replaceState(null, "", window.location.pathname + window.location.search);
  $("#pdfPreview").src = "about:blank";
}

function openFromHash() {
  const match = window.location.hash.match(/^#document=([0-9a-f]{32})$/);
  if (match && match[1] !== state.activeId) openViewer(match[1], false);
}

async function removeActiveDocument() {
  const document = activeDocument();
  if (!document || !window.confirm(`Remove “${document.filename}” from this local library? This deletes the stored file.`)) return;
  const response = await fetch(`/api/documents/${document.id}`, {method: "DELETE"});
  if (!response.ok) { showToast("Could not remove the document"); return; }
  closeViewer();
  await loadDocuments();
  showToast("Document removed");
}

grid.addEventListener("click", (event) => {
  const card = event.target.closest("[data-id]");
  if (card) openViewer(card.dataset.id);
});
$("#searchInput").addEventListener("input", (event) => { state.search = event.target.value; render(); });
$("#sortSelect").addEventListener("change", (event) => { state.sort = event.target.value; render(); });
document.querySelectorAll("[data-filter]").forEach((button) => button.addEventListener("click", () => {
  state.filter = button.dataset.filter;
  document.querySelectorAll("[data-filter]").forEach((item) => item.classList.toggle("active", item === button));
  render();
}));
$("#copyEndpoint").addEventListener("click", copyEndpoint);
$("#emptyEndpoint").addEventListener("click", copyEndpoint);
$("#closeViewer").addEventListener("click", closeViewer);
$("#previousDocument").addEventListener("click", () => moveViewer(-1));
$("#nextDocument").addEventListener("click", () => moveViewer(1));
$("#zoomOut").addEventListener("click", () => setZoom(state.zoom - .25));
$("#zoomIn").addEventListener("click", () => setZoom(state.zoom + .25));
$("#zoomReset").addEventListener("click", () => setZoom(1));
$("#imagePreview").addEventListener("dblclick", () => setZoom(state.zoom === 1 ? 2 : 1));
$("#deleteDocument").addEventListener("click", removeActiveDocument);
viewer.addEventListener("click", (event) => { if (event.target === viewer) closeViewer(); });
viewer.addEventListener("cancel", (event) => { event.preventDefault(); closeViewer(); });
window.addEventListener("hashchange", openFromHash);
window.addEventListener("keydown", (event) => {
  if (!viewer.open) return;
  if (event.key === "ArrowLeft") moveViewer(-1);
  if (event.key === "ArrowRight") moveViewer(1);
});

const today = new Date();
$("#dateDay").textContent = today.getDate();
$("#dateMonth").textContent = new Intl.DateTimeFormat(undefined, {month: "short"}).format(today);
$("#endpointLabel").textContent = endpoint().replace(/^https?:\/\//, "");
$("#emptyEndpoint code").textContent = endpoint();
loadDocuments();
setInterval(() => loadDocuments({quiet: true}), 5000);
