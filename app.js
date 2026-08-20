const form = document.querySelector('#setup-form');
const inputs = ['account','server','character'].map(id => document.querySelector(`#${id}`));
const output = Object.fromEntries(['account','server','character'].map(id => [id, document.querySelector(`#path-${id}`)]));
const errorBox = document.querySelector('#form-error');
const root = 'C:\\Program Files (x86)\\World of Warcraft\\_anniversary_\\';
const appScript = document.querySelector('script[src$="app.js"]');
const templateUrl = new URL('assets/options-template.zip', appScript?.src || document.baseURI);
const placeholders = { account: 'ACCOUNTNAME', server: 'SERVERNAME', character: 'CHARACTERNAME' };
const forbidden = /[<>:"/\\|?*\x00-\x1F]/;
const reserved = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i;
const wowUpField = document.querySelector('#wowup-import');
wowUpField.value = window.WOWUP_IMPORT || '';

document.querySelector('#copy-wowup').addEventListener('click', async () => {
  await copyText(wowUpField.value, wowUpField);
  toast('WowUp import string copied');
});

inputs.forEach(input => input.addEventListener('input', () => {
  output[input.id].textContent = input.value.trim() || placeholders[input.id];
  errorBox.hidden = true;
}));

function validate(value, label) {
  if (!value) return `${label} is required.`;
  if (forbidden.test(value) || /[. ]$/.test(value) || reserved.test(value)) return `${label} contains characters Windows can’t use in a folder name.`;
  return '';
}

function fullPath() { return root; }

document.querySelector('#copy-path').addEventListener('click', async () => {
  await copyText(fullPath());
  toast('Folder path copied');
});

async function copyText(value, sourceField) {
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(value);
  const field = sourceField || document.createElement('textarea');
  if (!sourceField) { field.value = value; field.style.position = 'fixed'; field.style.opacity = '0'; document.body.append(field); }
  field.select(); document.execCommand('copy');
  if (!sourceField) field.remove();
}

function toast(message) {
  const el = document.createElement('div'); el.className = 'toast'; el.textContent = message; document.body.append(el);
  setTimeout(() => el.remove(), 2200);
}

function decodeEmbeddedTemplate(encoded) {
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

form.addEventListener('submit', async event => {
  event.preventDefault();
  const values = Object.fromEntries(inputs.map(i => [i.id, i.value.trim()]));
  const problem = validate(values.account, 'Account folder') || validate(values.server, 'Server') || validate(values.character, 'Character');
  if (problem) { errorBox.textContent = problem; errorBox.hidden = false; return; }
  const button = form.querySelector('button[type="submit"]');
  button.disabled = true; button.firstElementChild.textContent = 'Building your download…';
  try {
    if (typeof JSZip === 'undefined') throw new Error('ZIP library failed to load');
    let templateBytes;
    if (window.TBC_TEMPLATE_BASE64) {
      templateBytes = decodeEmbeddedTemplate(window.TBC_TEMPLATE_BASE64);
    } else {
      const response = await fetch(templateUrl);
      if (!response.ok) throw new Error(`Template request failed (${response.status})`);
      templateBytes = await response.arrayBuffer();
    }
    const source = await JSZip.loadAsync(templateBytes);
    const result = new JSZip();
    const replacements = { ACCOUNTNAME: values.account, SERVERNAME: values.server, CHARACTERNAME: values.character };
    const textFile = /\.(txt|old|wtf|md5|lua|bak)$/i;
    for (const [path, entry] of Object.entries(source.files)) {
      const renamed = path.replace(/ACCOUNTNAME|SERVERNAME|CHARACTERNAME/g, key => replacements[key]);
      if (entry.dir) {
        result.folder(renamed);
      } else if (textFile.test(path)) {
        const contents = await entry.async('string');
        result.file(renamed, contents.replace(/ACCOUNTNAME|SERVERNAME|CHARACTERNAME/g, key => replacements[key]), { date: entry.date });
      } else {
        result.file(renamed, await entry.async('uint8array'), { binary: true, date: entry.date });
      }
    }
    const blob = await result.generateAsync({ type: 'blob', compression: 'DEFLATE', compressionOptions: { level: 6 } });
    const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = `${values.character}-${values.server}-TBC-settings.zip`; link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000); toast('Your folder is ready');
  } catch (error) {
    console.error(error);
    errorBox.textContent = error.message.includes('ZIP library')
      ? 'The ZIP generator could not load. Refresh the page and try again.'
      : 'The settings download could not be opened. Extract the full website folder and try again.';
    errorBox.hidden = false;
  } finally { button.disabled = false; button.firstElementChild.textContent = 'Generate my folder'; }
});


const previewImage = document.querySelector('.ui-preview figure img');
const previewDialog = document.getElementById('preview-dialog');
const openPreview = document.getElementById('open-preview');
const closePreview = document.getElementById('close-preview');

if (previewImage && previewDialog && openPreview && closePreview) {
  const dialogImage = previewDialog.querySelector('.dialog-image');
  const closeDialog = () => {
    previewDialog.close();
    document.body.classList.remove('dialog-open');
  };

  openPreview.addEventListener('click', () => {
    if (!dialogImage.firstElementChild) {
      const fullImage = previewImage.cloneNode();
      fullImage.removeAttribute('loading');
      fullImage.alt = previewImage.alt;
      dialogImage.appendChild(fullImage);
    }
    previewDialog.showModal();
    document.body.classList.add('dialog-open');
    closePreview.focus();
  });

  closePreview.addEventListener('click', closeDialog);
  previewDialog.addEventListener('click', (event) => {
    if (event.target === previewDialog) closeDialog();
  });
  previewDialog.addEventListener('close', () => document.body.classList.remove('dialog-open'));
}
