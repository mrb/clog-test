exports._id = 'designs'

_ = require('lodash')
async = require('async')
archiver = require('archiver')


config = require('../../../conf')
log = require('../../../lib/log')
Design = require('./design_model')
S3 = require('../../../lib/s3')
s3 = new S3.Bucket
  key: config.get('aws:access_key')
  secret: config.get('aws:secret_key')
  bucket: config.get('designs:bucket')
  region: config.get('designs:bucket_region')
  headers: 'x-amz-acl': 'public-read'

exports.index = (req, res) ->
  Design.find req.query, req.options, (err, designs) ->
    return res.error(err) if err
    res.success({designs})


exports.get = (req, res) ->
  Design.findOne
    name: req.params.name
  , (err, design) ->
    return res.error(err) if err
    return res.error(404) unless design
    res.success(design: design)


exports.getVersion = (req, res, next) ->
  Design.findOne
    name: req.params.name
  , (err, design) ->
    return next(err) if err || !design ||
      !(version = design.getVersion(req.params.version, withBasePath: true))
    res.success(version)


exports.setLatestVersion = (req, res, next) ->
  Design.findOne
    name: req.params.name
  , (err, design) ->
    return res.error(err) if err
    return res.error(404) if !design
    return res.error(403) if !design.isEditableBy(req.user)
    return res.error(400, version: 'Not available') unless design.setVersion(req.body.version)
    design.save (err) ->
      return next(err) if err
      res.success(design.getVersion('latest'))


exports.updateVersion = (req, res, next) ->
  findOrCreateDesign
    name: req.params.name
    user: req.user
  , (err, design) ->
    return res.error(err) if err
    return res.error(404) if !design
    return res.error(400, err) if err = validateDesign(req.params, req.body)

    design.addVersion(req.body)
    design.save (err) ->
      return next(err) if err
      res.success(design.getVersion(req.params.version))


findOrCreateDesign = ({name, user}, callback) ->
  Design.findOne {name}, (err, design) ->
    return callback(err) if err
    return callback() if design && !design.isEditableBy(user)
    design = new Design({name, author_id: user.id}) unless design
    callback(null, design)


validateDesign = (params, body) ->
  err = null
  if body.private
    err = setError(err, 'private', "This design has been marked as private.
      Remove the 'private' field from the json to publish it.")
  _.each ['name', 'version'], (param) ->
    unless body[param] == params[param]
      err = setError(err, param, "The #{param} in the body does not match the one in the url")
  err


setError = (error, type, string) ->
  error ?= {}
  error[type] = string
  error


exports.getDesignTarFile = (req, res, next) ->
  Design.findOne
    name: req.params.name
  , (err, design) ->
    return next(err) if err || !design || !(version = design.getVersion(req.params.version))
    s3.list version.basePath(), (err, files) ->
      return next(err) if err

      archive = archiver 'tar',
        gzip: true
        gzipOptions: level: 6

      try
        packageJSON = version.toPackage()
        archive.append(packageJSON, {name: "#{packageJSON.name}/package.json"})
        archive.append(packageJSON, {name: "#{packageJSON.name}/bower.json"})
        archive.append(version.toJson(false), {name: "#{packageJSON.name}/design.json"})
        archive.append(version.toJs(true), {name: "#{packageJSON.name}/design.js"})
      catch err
        return next(err)

      async.each files, (file, done) ->
        return done() unless file.Size
        s3.getStream file.Key, (err, stream) ->
          return done(err) if err
          if fileName = version.barePath(file.Key)
            archive.append(stream, name: "#{packageJSON.name}/#{fileName}", size: file.Size)
          else
            log.error("Failed to append the file #{file.Key} to the tar archive.")
          done()
      , (err) ->
        log.error(err) if err
        archive.finalize()

      res.header('content-type', 'application/x-gzip')
      res.header('content-encoding', 'gzip')
      archive.pipe(res)


exports.listAssets = (req, res, next) ->
  Design.findOne
    name: req.params.name
  , (err, design) ->
    return next(err) if err || !design || !(version = design.getVersion(req.params.version))
    s3.list version.basePath(), (err, files) ->
      return next(err) if err

      assets = []
      _.each files, (file) ->
        if file.Size
          assets.push
            url: version.publicPath(file.Key)
            size: file.Size

      res.success(200, {assets})


exports.uploadAsset = (req, res, next) ->
  Design.findOne
    name: req.params.name
  , (err, design) ->
    return next(err) if err
    return res.error(404) if !design || !(version = design.getVersion(req.params.version))
    return res.error(400, file: 'Missing required property: file') unless file = req.files.file

    bucketPath = version.filePath(req.body.path)
    s3.putFile bucketPath, file.path, (err) ->
      return next(err) if err
      res.success 201,
        asset:
          url: version.publicPath(bucketPath)
          size: file.size


exports.delete = (req, res, next) ->
  Design.findOne
    name: req.params.name
  , (err, design) ->
    return next(err) if err
    return res.error(403) if design && !design.isEditableBy(req.user)
    return res.success(200) if !design

    s3.deleteList "/#{design.name}", (err) ->
      return next(err) if err

      design.destroy (err) ->
        return next(err) if err
        res.success(200)
