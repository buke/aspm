
fs = require 'fs'
path = require 'path'
os = require 'os'
exec = require('child_process').exec

queue = require 'queue-async'
semver = require 'semver'
require 'terminal-colors'


# modified from https://gist.github.com/liangzan/807712#comment-337828
rmDirRecursiveSync = (dirPath) ->
	try
		files = fs.readdirSync(dirPath)
	catch e
		return
	if files.length > 0
		i = 0
		while i < files.length
			filePath = dirPath + "/" + files[i]
			if fs.statSync(filePath).isFile()
				fs.unlinkSync(filePath)
			else
				rmDirRecursiveSync filePath
			i++
	try fs.rmdirSync dirPath
	return

module.exports.runCmd = runCmd = (cmd, opts, quiet, cb) ->
	console.log "#{opts.cwd or ''}> #{cmd}".lightBlue unless quiet
	errMsg = ''
	child = exec cmd, opts
	child.stdout.pipe process.stdout unless quiet
	unless quiet
		child.stderr.pipe process.stderr
	else
		child.stderr.on 'data', (chunk) -> errMsg += chunk; return

	child.on 'exit', (code) ->
		return cb?(new Error "command failed: #{cmd}\n#{errMsg}") if code isnt 0
		cb?()
	return

configureModule = (moduleName, opts, nodePreGypParams, cb) ->
	cmd = "node-gyp configure #{nodePreGypParams}"

	cmdOpts =
		cwd: path.join 'node_modules', moduleName
	cmdOpts.cwd = path.join opts.cwd, cmdOpts.cwd if opts.cwd
	runCmd cmd, cmdOpts, opts.quiet, cb
	return
	
module.exports.fetchModule = fetchModule = (moduleName, opts, cb) ->
	console.log "fetching #{moduleName or 'all'}" unless opts.quiet
	moduleName ?= ''
	moduleName = opts.tarball if opts.tarball
	cmd = "npm install #{moduleName}"
	cmd += ' --ignore-scripts' unless opts.runScripts
	cmd += ' --save' if opts.save
	cmd += ' --save-dev' if opts.saveDev
	cmdOpts = {}
	cmdOpts.cwd = opts.cwd if opts.cwd
	runCmd cmd, cmdOpts, opts.quiet, cb
	return

module.exports.buildModule = buildModule = (moduleName, opts, cb) ->
	projectPkg = require path.join process.cwd(), 'package.json'
	config = projectPkg.config?['atom-shell']
	target = opts.target or config?.version
	arch = opts.arch or config?.arch
	platform = opts['target-platform'] or config?['platform'] or os.platform()
	modules = []
	nodePreGypParams = ''

	modules = moduleName.split ' ' if moduleName.indexOf(' ') isnt -1
	modules = Object.keys projectPkg.dependencies unless moduleName

	if modules.length isnt 0
		# build multiple modules serially and return
		q = queue(1)
		for moduleName in modules
			q.defer buildModule, moduleName
			q.awaitAll (err) ->
				return cb()
		return
	
	[moduleName] = moduleName.split '@' # get rid of version

	cwd = process.cwd()
	cwd = path.join cwd, opts.cwd if opts.cwd
	modulePath = path.join cwd, 'node_modules', moduleName

	# error if module is not found
	return cb?(new Error("aspm: module not found '#{moduleName}'")) unless fs.existsSync path.join modulePath, 'package.json'
	# skip if module has no bynding.gyp
	return cb() unless fs.existsSync path.join modulePath, 'binding.gyp'
	
	return cb?(new Error "aspm: no atom-shell version specified.") unless target
	return cb?(new Error "aspm: no target architecture specified.") unless arch

	buildPkg = require path.join modulePath, 'package.json'

	fakeNodePreGyp = buildPkg.dependencies?['node-pre-gyp']? and buildPkg.binary?
	if fakeNodePreGyp
		nodePreGypPkg = require path.join modulePath, 'node_modules', 'node-pre-gyp', 'package.json'
		nodePreGypVersion = nodePreGypPkg.version

		node_abi = "atom-shell-v#{target}"
		if semver.lte nodePreGypVersion, '999.0.0' # some future version with atom-shell support
			node_abi = do ->
				atomshellToModulesVersion =
					'0.21.x': 41
					'0.20.x': 17
					"0.19.x": 16
					"0.18.x": 16
					"0.17.x": 15
					"0.16.x": 14
				atomshellToNodeVersion =
					'0.21.x': '1.0.0-pre'
					'0.20.x': '0.13.0-pre'
					'0.19.x': '0.11.14'
					'0.18.x': '0.11.14'
					'0.17.x': '0.11.14'
					'0.16.x': '0.11.13'
					#'0.15.x': '0.11.13'
					#'0.14.x': '0.11.13'
					#'0.13.x': '0.11.10'
					#'0.12.x': '0.11.10'
					#'0.11.x': '0.11.10'
					#'0.10.x': '0.11.10'
					#'0.9.x': '0.11.10'
					#'0.8.x': '0.11.10'
					#'0.7.x': '0.10.18'
					#'0.6.x': '0.10.18'

				lookupTable = do ->
					return atomshellToModulesVersion if semver.lt nodePreGypVersion, '0.6.0'
					return atomshellToNodeVersion

				targetParts = target.split '.'
				targetParts[2] = 'x'
				targetSimplified = targetParts.join '.'
				return "node-v#{lookupTable[targetSimplified]}"

		module_path = buildPkg.binary.module_path
		# fake node-pre-gyp
		module_path = module_path
		.replace '{node_abi}', node_abi
		.replace '{platform}', os.platform()
		.replace '{arch}', arch
		.replace '{module_name}', buildPkg.binary.module_name
		.replace '{configuration}', 'Release'
		.replace '{version}', buildPkg.version
		
		preGyp =
			module_name: buildPkg.binary.module_name
			module_path: path.join '..', module_path

	if fakeNodePreGyp
		nodePreGypParams += " --module_name=#{preGyp.module_name}"
		nodePreGypParams += " --module_path=#{preGyp.module_path}"

	# run pre-scripts from package.json
	q = queue(1)
	preScripts = 'prepublish preinstall'.split ' '
	preScripts.push 'install' if opts.compatibility
	cmdOpts =
		cwd: path.join 'node_modules', moduleName
	cmdOpts.cwd = path.join opts.cwd, cmdOpts.cwd if opts.cwd
	for scriptName in preScripts
		if buildPkg.scripts?[scriptName]?
			cmd = "npm run #{scriptName}"
			q.defer runCmd, cmd, cmdOpts, opts.quiet
	q.awaitAll (err) ->
		configureModule moduleName, opts, nodePreGypParams, (err) ->
			console.log "building #{moduleName} for Atom-Shell v#{target} #{os.platform()} #{arch}" unless opts.quiet

			cmd = "node-gyp rebuild --target=#{target} --arch=#{arch} --target_platform=#{platform} --dist-url=https://gh-contractor-zcbenz.s3.amazonaws.com/atom-shell/dist #{nodePreGypParams}"

			runCmd cmd, cmdOpts, opts.quiet, (err) ->
				return cb?(err) if err
				###
				unless fakeNodePreGyp
					# we move the node_module.node file to lib/binding
					try fs.mkdirSync "node_modules/#{moduleName}/lib/binding"
					fs.renameSync "node_modules/#{moduleName}/build/Release/node_#{moduleName}.node", "node_modules/#{moduleName}/lib/binding/node_#{moduleName}.node"
				rmDirRecursiveSync "node_modules/#{moduleName}/build/"
				###

				# run post-scripts from package.json
				q = queue(1)
				for scriptName in 'postinstall'.split ' ' # also 'install'?
					if buildPkg.scripts?[scriptName]?
						cmd = "npm run #{scriptName}"
						q.defer runCmd, cmd, cmdOpts, opts.quiet
				q.awaitAll (err) ->
					return cb?()
			return
		return
	return

module.exports.installModule = (moduleName, opts, cb) ->
	console.log "installing #{moduleName or 'all'}" unless opts.quiet
	fetchModule moduleName, opts, (err) ->
		return cb?(err) if err
		buildModule moduleName, opts, (err) ->
			return cb?(err)
		return
	return
