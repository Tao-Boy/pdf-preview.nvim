local M = {}

local DEFAULT_OPTS = {
	port = nil,
	reload_debouce = 500,
	preview_scale = 1.5,
}

local data_path = vim.fn.stdpath("data") .. "/pdf-preview"
local server_process = nil

local function install_browser_sync()
	local result = nil

	vim.fn.mkdir(data_path, "p")

	if not vim.uv.fs_stat(data_path .. "/package.json") then
		result = vim.system({ "npm", "init", "-y" }, { cwd = data_path }):wait()
		if result.code ~= 0 then
			error("Failed to initialize npm: " .. result.stderr)
		end
	end

	result = vim.system({ "npm", "list", "browser-sync", "pdfjs-dist" }, { cwd = data_path }):wait()
	if result.code == 0 then
		return
	end

	vim.notify("Installing dependencies (browser-sync, pdfjs-dist)...", vim.log.levels.INFO)
	result = vim.system({ "npm", "install", "browser-sync", "pdfjs-dist" }, { cwd = data_path }):wait()
	if result.code ~= 0 then
		error("Failed to install dependencies: " .. result.stderr)
	else
		vim.notify("Dependencies successfully installed", vim.log.levels.INFO)
	end
end

local function start_preview(pdf_filepath)
	local server_root_path = vim.fn.tempname()
	vim.fn.mkdir(server_root_path, "p")

	local pdf_filename = vim.fs.basename(pdf_filepath)
	local server_pdf_filepath = ("%s/%s"):format(server_root_path, pdf_filename)
	if not vim.uv.fs_symlink(pdf_filepath, server_pdf_filepath, nil) then
		error("Failed to symlink PDF file: " .. server_pdf_filepath)
	end

	local node_modules_src = data_path .. "/node_modules"
	local node_modules_dst = server_root_path .. "/node_modules"
	if not vim.uv.fs_symlink(node_modules_src, node_modules_dst, { dir = true }) then
		error("Failed to symlink node_modules")
	end

	local html_filepath = server_root_path .. "/index.html"
	local html_content = string.format(
		[[
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>PDF Preview</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { 
      height: 100%%;
      overflow: auto;
      background-color: #525252;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Noto Sans CJK SC", sans-serif;
    }
    #controls {
      position: fixed;
      top: 10px;
      right: 10px;
      background: rgba(0, 0, 0, 0.8);
      color: white;
      padding: 12px 16px;
      border-radius: 6px;
      font-size: 13px;
      z-index: 1000;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
    }
    #controls > div {
      margin-bottom: 4px;
    }
    #controls > div:last-child {
      margin-bottom: 0;
    }
    #pdf-container { 
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 20px 0;
      min-height: 100%%;
    }
    .pdf-page-wrapper {
      position: relative;
      margin-bottom: 10px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      /* 保持尺寸稳定，避免布局闪烁 */
      background: white;
    }
    .pdf-page { 
      display: block;
      background: white;
      /* 关键：确保 canvas 不会在更新时闪烁 */
      image-rendering: -webkit-optimize-contrast;
      image-rendering: crisp-edges;
    }
    /* 移除更新时的透明度变化效果 */
    #loading {
      color: white;
      text-align: center;
      padding: 20px;
      font-size: 14px;
    }
    .status-ready { color: #4ade80; }
    .status-updating { color: #fbbf24; }
    .status-error { color: #ef4444; }
    
    /* 添加淡入动画，使首次加载更平滑 */
    @keyframes fadeIn {
      from { opacity: 0; }
      to { opacity: 1; }
    }
    .pdf-page-wrapper.loaded {
      animation: fadeIn 0.2s ease-in;
    }
  </style>
</head>
<body>
  <div id="controls">
    <div>状态: <span id="status" class="status-ready">初始化...</span></div>
    <div>页数: <span id="page-count">-</span></div>
    <div>缩放: <span id="scale-info">%s</span></div>
  </div>
  <div id="loading">正在加载 PDF...</div>
  <div id="pdf-container"></div>

  <script type="module">
    import * as pdfjsLib from './node_modules/pdfjs-dist/build/pdf.mjs';
    
    pdfjsLib.GlobalWorkerOptions.workerSrc = './node_modules/pdfjs-dist/build/pdf.worker.mjs';

    const PDF_URL = '%s';
    const SCALE = %s;
    const CHECK_INTERVAL = 300;
    
    let pdfDoc = null;
    let currentScrollPos = 0;
    let currentScrollPercent = 0;
    let lastFileSize = 0;
    let lastModified = null;
    let isRendering = false;
    let renderQueue = [];
    // 存储每页的渲染任务，用于取消旧的渲染
    let pageRenderTasks = new Map();

    const container = document.getElementById('pdf-container');
    const loading = document.getElementById('loading');
    const statusEl = document.getElementById('status');
    const pageCountEl = document.getElementById('page-count');

    function updateStatus(text, type = 'ready') {
      statusEl.textContent = text;
      statusEl.className = `status-${type}`;
    }

    function saveScrollPosition() {
      const scrollTop = window.scrollY || document.documentElement.scrollTop;
      const scrollHeight = document.documentElement.scrollHeight - window.innerHeight;
      currentScrollPos = scrollTop;
      currentScrollPercent = scrollHeight > 0 ? scrollTop / scrollHeight : 0;
    }

    function restoreScrollPosition() {
      requestAnimationFrame(() => {
        const scrollHeight = document.documentElement.scrollHeight - window.innerHeight;
        const targetScroll = scrollHeight > 0 ? currentScrollPercent * scrollHeight : currentScrollPos;
        window.scrollTo({
          top: targetScroll,
          behavior: 'instant'
        });
      });
    }

    // 使用离屏 canvas 进行双缓冲渲染，避免闪烁
    async function renderPageDoubleBuffered(pageNum, targetCanvas) {
      try {
        // 取消该页面之前的渲染任务
        if (pageRenderTasks.has(pageNum)) {
          const oldTask = pageRenderTasks.get(pageNum);
          if (oldTask && oldTask.cancel) {
            oldTask.cancel();
          }
        }

        const page = await pdfDoc.getPage(pageNum);
        const viewport = page.getViewport({ scale: SCALE });
        
        // 创建离屏 canvas 进行渲染
        const offscreenCanvas = document.createElement('canvas');
        offscreenCanvas.width = viewport.width;
        offscreenCanvas.height = viewport.height;
        const offscreenContext = offscreenCanvas.getContext('2d', {
          alpha: false,  // 禁用 alpha 通道提升性能
          willReadFrequently: false
        });
        
        // 设置白色背景，避免透明导致的闪烁
        offscreenContext.fillStyle = 'white';
        offscreenContext.fillRect(0, 0, viewport.width, viewport.height);
        
        const renderContext = {
          canvasContext: offscreenContext,
          viewport: viewport,
          // 使用渲染意图优化
          intent: 'display',
          enableWebGL: false,
          renderInteractiveForms: false,
        };
        
        // 开始渲染并保存任务引用
        const renderTask = page.render(renderContext);
        pageRenderTasks.set(pageNum, renderTask);
        
        await renderTask.promise;
        
        // 渲染完成后，一次性将离屏 canvas 复制到目标 canvas
        // 这样可以避免渲染过程中的中间状态导致的闪烁
        if (targetCanvas.width !== viewport.width || targetCanvas.height !== viewport.height) {
          targetCanvas.width = viewport.width;
          targetCanvas.height = viewport.height;
        }
        
        const targetContext = targetCanvas.getContext('2d', {
          alpha: false,
          willReadFrequently: false
        });
        
        // 使用 drawImage 一次性复制，这是原子操作，不会闪烁
        targetContext.drawImage(offscreenCanvas, 0, 0);
        
        // 清理引用
        pageRenderTasks.delete(pageNum);
        
      } catch (error) {
        if (error.name === 'RenderingCancelledException') {
          console.log(`Rendering cancelled for page ${pageNum}`);
        } else {
          console.error(`Error rendering page ${pageNum}:`, error);
          throw error;
        }
      }
    }

    async function processRenderQueue() {
      if (isRendering || renderQueue.length === 0) return;
      
      isRendering = true;
      
      // 批量处理渲染队列，避免阻塞
      while (renderQueue.length > 0) {
        const batch = renderQueue.splice(0, 3); // 每次处理 3 页
        await Promise.all(
          batch.map(({ pageNum, canvas }) => 
            renderPageDoubleBuffered(pageNum, canvas)
          )
        );
        
        // 让出控制权，避免阻塞 UI
        await new Promise(resolve => setTimeout(resolve, 0));
      }
      
      isRendering = false;
    }

    async function loadPDF(isUpdate = false) {
      try {
        updateStatus(isUpdate ? '更新中...' : '加载中...', 'updating');
        
        if (isUpdate) {
          saveScrollPosition();
          // 不再添加 updating 类，避免透明度变化
        }

        const loadingTask = pdfjsLib.getDocument({
          url: `${PDF_URL}?t=${Date.now()}`,
          cMapUrl: './node_modules/pdfjs-dist/cmaps/',
          cMapPacked: true,
          standardFontDataUrl: './node_modules/pdfjs-dist/standard_fonts/',
          useSystemFonts: false,
          disableFontFace: false,
        });
        
        const newPdfDoc = await loadingTask.promise;
        
        const pageCountChanged = pdfDoc && (pdfDoc.numPages !== newPdfDoc.numPages);
        pdfDoc = newPdfDoc;
        
        pageCountEl.textContent = pdfDoc.numPages;
        loading.style.display = 'none';

        // 更新策略：直接在现有 canvas 上渲染，不重建 DOM
        if (isUpdate && !pageCountChanged && container.children.length === pdfDoc.numPages) {
          // 逐页更新现有 canvas（双缓冲，无闪烁）
          renderQueue = [];
          for (let i = 0; i < container.children.length; i++) {
            const canvas = container.children[i].querySelector('canvas');
            renderQueue.push({ pageNum: i + 1, canvas });
          }
          await processRenderQueue();
        } else {
          // 首次加载或页数变化：重建 DOM
          container.innerHTML = '';
          renderQueue = [];
          
          for (let pageNum = 1; pageNum <= pdfDoc.numPages; pageNum++) {
            const wrapper = document.createElement('div');
            wrapper.className = 'pdf-page-wrapper';
            
            // 预先设置尺寸，避免布局跳动
            const page = await pdfDoc.getPage(pageNum);
            const viewport = page.getViewport({ scale: SCALE });
            wrapper.style.width = viewport.width + 'px';
            wrapper.style.height = viewport.height + 'px';
            
            const canvas = document.createElement('canvas');
            canvas.className = 'pdf-page';
            // 设置初始尺寸
            canvas.width = viewport.width;
            canvas.height = viewport.height;
            
            wrapper.appendChild(canvas);
            container.appendChild(wrapper);
            
            renderQueue.push({ pageNum, canvas });
          }
          
          await processRenderQueue();
          
          // 添加淡入效果
          container.querySelectorAll('.pdf-page-wrapper').forEach(wrapper => {
            wrapper.classList.add('loaded');
          });
        }

        if (isUpdate) {
          restoreScrollPosition();
        }

        updateStatus('就绪', 'ready');
        console.log('PDF loaded successfully');
      } catch (error) {
        console.error('Error loading PDF:', error);
        loading.innerHTML = `<div style="color: #ef4444;">加载 PDF 出错: ${error.message}</div>`;
        updateStatus('错误', 'error');
      }
    }

    async function checkForUpdates() {
      try {
        const response = await fetch(PDF_URL, { 
          method: 'HEAD',
          cache: 'no-cache'
        });
        
        if (!response.ok) return;
        
        const contentLength = response.headers.get('content-length');
        const newFileSize = contentLength ? parseInt(contentLength) : 0;
        const newModified = response.headers.get('last-modified');
        
        if ((lastFileSize > 0 && newFileSize !== lastFileSize) ||
            (lastModified && newModified !== lastModified)) {
          console.log('PDF updated, reloading...');
          lastFileSize = newFileSize;
          lastModified = newModified;
          await loadPDF(true);
        } else if (lastFileSize === 0) {
          lastFileSize = newFileSize;
          lastModified = newModified;
        }
      } catch (error) {
        console.debug('Check update error:', error);
      }
    }

    let scrollTimeout;
    window.addEventListener('scroll', () => {
      clearTimeout(scrollTimeout);
      scrollTimeout = setTimeout(saveScrollPosition, 100);
    });

    if (window.___browserSync___) {
      const bs = window.___browserSync___;
      bs.socket.on('browser:reload', (data) => {
        console.log('Browser-sync reload blocked, using custom update');
        return false;
      });
    }

    // 初始加载
    await loadPDF(false);

    // 定期检查更新
    setInterval(checkForUpdates, CHECK_INTERVAL);
  </script>
</body>
</html>
]],
		M.opts.preview_scale,
		pdf_filename,
		M.opts.preview_scale
	)

	local html_file = io.open(html_filepath, "w")
	if not html_file then
		error("Could not open file for writing: " .. html_filepath)
	end
	html_file:write(html_content)
	html_file:close()

	local command = {
		"npx",
		"browser-sync",
		"start",
		"--server",
		server_root_path,
		"--no-ui",
		"--no-open",
		"--no-ghost-mode",
		"--no-inject-changes",
		"--no-reload-on-restart",
	}
	
	if M.opts.port then
		table.insert(command, "--port")
		table.insert(command, tostring(M.opts.port))
	end
	
	server_process = vim.fn.jobstart(command, {
		cwd = data_path,
		pty = true,
		on_stdout = function(_, data, _)
			local port = nil
			for _, line in ipairs(data) do
				port = line:match("http://localhost:(%d+)")
				if port then
					vim.notify("PDF preview started", vim.log.levels.INFO)
					vim.notify("Connect at http://localhost:" .. port, vim.log.levels.INFO)
					break
				end
			end
		end,
	})
end

M.start_preview = function()
	if server_process then
		vim.notify("PDF preview is already running", vim.log.levels.INFO)
		return
	end

	local cwd = vim.fn.getcwd()
	vim.ui.input({
		prompt = ("Enter the PDF filepath: %s/"):format(cwd),
		completion = "file",
	}, function(input)
		if input then
			local pdf_filepath = cwd .. "/" .. input
			start_preview(pdf_filepath)
		end
	end)
end

M.stop_preview = function()
	if not server_process then
		vim.notify("PDF preview is not running", vim.log.levels.INFO)
		return
	end

	if server_process then
		vim.fn.jobstop(server_process)
		server_process = nil
	end

	vim.notify("PDF preview stopped", vim.log.levels.INFO)
end

M.toggle_preview = function()
	if server_process then
		M.stop_preview()
	else
		M.start_preview()
	end
end

M.setup = function(opts)
	M.opts = vim.tbl_deep_extend("force", DEFAULT_OPTS, opts or {})

	install_browser_sync()

	vim.api.nvim_create_user_command("PdfPreviewStart", M.start_preview, {})
	vim.api.nvim_create_user_command("PdfPreviewStop", M.stop_preview, {})
	vim.api.nvim_create_user_command("PdfPreviewToggle", M.toggle_preview, {})
end

return M
