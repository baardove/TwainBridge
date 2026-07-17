const uploadForm = document.querySelector("#manualUploadForm");
const fileInput = document.querySelector("#manualFiles");
const manifestInput = document.querySelector("#manifestInput");
const batchInput = document.querySelector("#batchId");
const sourceInput = document.querySelector("#sourceName");
const uploadButton = document.querySelector("#uploadButton");
let toastTimer;

function endpoint() { return `${window.location.origin}/upload`; }

function showToast(message) {
  const toast = document.querySelector("#toast");
  toast.textContent = message;
  toast.classList.add("visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove("visible"), 2200);
}

async function copyEndpoint() {
  try {
    await navigator.clipboard.writeText(endpoint());
    document.querySelector("#copyLabel").textContent = "Copied";
    showToast("Upload endpoint copied");
    setTimeout(() => { document.querySelector("#copyLabel").textContent = "Copy"; }, 1800);
  } catch {
    showToast(endpoint());
  }
}

function selectedFiles() { return Array.from(fileInput.files || []); }

function refreshFileLabel() {
  const files = selectedFiles();
  const label = document.querySelector("#fileSelectionLabel");
  if (!files.length) { label.textContent = "No files selected · 100 MB maximum per file"; return; }
  const bytes = files.reduce((sum, file) => sum + file.size, 0);
  const size = bytes < 1024 * 1024 ? `${Math.ceil(bytes / 1024)} KB` : `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  label.textContent = `${files.length} file${files.length === 1 ? "" : "s"} selected · ${size}`;
}

function generateManifest() {
  const files = selectedFiles();
  if (!files.length) { showToast("Choose files before generating a manifest"); return; }
  const batchId = batchInput.value.trim() || crypto.randomUUID();
  batchInput.value = batchId;
  manifestInput.value = JSON.stringify({
    batch_id: batchId,
    documents: files.map((file) => ({
      document_id: crypto.randomUUID(),
      filename: file.name,
      page_count: 1,
      scanned_at: new Date().toISOString(),
      ...(sourceInput.value.trim() ? {source: sourceInput.value.trim()} : {})
    }))
  }, null, 2);
  showToast("Manifest generated");
}

function showResult(response, payload) {
  const result = document.querySelector("#uploadResult");
  const success = response.ok && payload.success !== false;
  document.querySelector("#resultEyebrow").textContent = success ? "Receiver accepted the upload" : `HTTP ${response.status}`;
  document.querySelector("#resultTitle").textContent = success ? "Upload complete" : "Upload rejected";
  document.querySelector("#resultMessage").textContent = payload.message || (success ? "Documents were stored." : "Review the response details below.");
  document.querySelector("#resultJson").textContent = JSON.stringify(payload, null, 2);
  const openLink = document.querySelector("#openUploadedDocument");
  openLink.hidden = !payload.open_url;
  if (payload.open_url) openLink.href = payload.open_url;
  result.classList.toggle("failed", !success);
  result.hidden = false;
  result.scrollIntoView({behavior: "smooth", block: "nearest"});
}

async function upload(event) {
  event.preventDefault();
  const files = selectedFiles();
  if (!files.length) { fileInput.reportValidity(); return; }
  const manifest = manifestInput.value.trim();
  if (manifest) {
    try {
      const parsed = JSON.parse(manifest);
      if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.documents)) throw new Error();
    } catch {
      manifestInput.setCustomValidity("Manifest must be a JSON object containing a documents array.");
      manifestInput.reportValidity();
      return;
    }
  }
  manifestInput.setCustomValidity("");
  const data = new FormData();
  files.forEach((file) => data.append("file", file, file.name));
  new FormData(uploadForm).forEach((value, key) => {
    if (key !== "file" && String(value).trim()) data.append(key, value);
  });

  uploadButton.disabled = true;
  uploadButton.textContent = "Uploading…";
  try {
    const response = await fetch("/upload", {method: "POST", body: data});
    let payload;
    try { payload = await response.json(); }
    catch { payload = {success: false, message: "The receiver did not return JSON."}; }
    showResult(response, payload);
  } catch (error) {
    showResult({ok: false, status: 0}, {success: false, message: `Could not reach the receiver: ${error.message}`});
  } finally {
    uploadButton.disabled = false;
    uploadButton.textContent = "Upload documents";
  }
}

document.querySelector("#uploadEndpoint").textContent = endpoint();
document.querySelector("#configurationEndpoint").textContent = endpoint();
document.querySelector("#copyUploadEndpoint").addEventListener("click", copyEndpoint);
document.querySelector("#generateManifest").addEventListener("click", generateManifest);
fileInput.addEventListener("change", refreshFileLabel);
manifestInput.addEventListener("input", () => manifestInput.setCustomValidity(""));
uploadForm.addEventListener("submit", upload);
