CompileController = require "./app/js/CompileController"
Settings = require "settings-sharelatex"
logger = require "logger-sharelatex"
logger.initialize("clsi")
smokeTest = require "smoke-test-sharelatex"

Path = require "path"
fs = require "fs"

Metrics = require "metrics-sharelatex"
Metrics.initialize("clsi")
Metrics.open_sockets.monitor(logger)

ProjectPersistenceManager = require "./app/js/ProjectPersistenceManager"

require("./app/js/db").sync()

express = require "express"
bodyParser = require "body-parser"
app = express()

app.use Metrics.http.monitor(logger)

# Compile requests can take longer than the default two
# minutes (including file download time), so bump up the 
# timeout a bit.
TIMEOUT = 6 * 60 * 1000
app.use (req, res, next) ->
	req.setTimeout TIMEOUT
	res.setTimeout TIMEOUT
	next()

app.post   "/project/:project_id/compile", bodyParser.json(limit: "5mb"), CompileController.compile
app.delete "/project/:project_id", CompileController.clearCache

app.get  "/project/:project_id/sync/code", CompileController.syncFromCode
app.get  "/project/:project_id/sync/pdf", CompileController.syncFromPdf

staticServer = express.static Settings.path.compilesDir, setHeaders: (res, path, stat) ->
	if Path.basename(path) == "output.pdf"
		res.set("Content-Type", "application/pdf")
		# Calculate an etag in the same way as nginx
		# https://github.com/tj/send/issues/65
		etag = (path, stat) ->
			'"' + Math.ceil(+stat.mtime / 1000).toString(16) +
			'-' + Number(stat.size).toString(16) + '"'
		res.set("Etag", etag(path, stat))
	else
		# Force plain treatment of other file types to prevent hosting of HTTP/JS files
		# that could be used in same-origin/XSS attacks.
		res.set("Content-Type", "text/plain")

app.get "/project/:project_id/output/*", require("./app/js/SymlinkCheckerMiddlewear"), (req, res, next) ->
	req.url = "/#{req.params.project_id}/#{req.params[0]}"
	staticServer(req, res, next)

app.get "/status", (req, res, next) ->
	res.send "CLSI is alive\n"

resCacher =
	contentType:(@setContentType)->
	send:(@code, @body)->

	#default the server to be down
	code:500
	body:{}
	setContentType:"application/json"

if Settings.smokeTest
	do runSmokeTest = ->
		logger.log("running smoke tests")
		smokeTest.run(require.resolve(__dirname + "/test/smoke/js/SmokeTests.js"))({}, resCacher)
		setTimeout(runSmokeTest, 20 * 1000)

app.get "/health_check", (req, res)->
	res.contentType(resCacher?.setContentType)
	res.send resCacher?.code, resCacher?.body

app.use (error, req, res, next) ->
	logger.error err: error, "server error"
	res.send error?.statusCode || 500

app.listen port = (Settings.internal?.clsi?.port or 3013), host = (Settings.internal?.clsi?.host or "localhost"), (error) ->
	logger.log "CLSI listening on #{host}:#{port}"

setInterval () ->
	ProjectPersistenceManager.clearExpiredProjects()
, tenMinutes = 10 * 60 * 1000
