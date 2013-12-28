{isEqual, extend, omit, pick, size} = require 'underscore'
{Emitter} = require 'emissary'
MarkerPatch = require './marker-patch'
Point = require './point'
Range = require './range'

module.exports =
class Marker
  Emitter.includeInto(this)

  @reservedKeys: ['isReversed', 'hasTail', 'invalidate', 'persistent', 'persist']

  @paramsFromOptions: (options) ->
    params = {}
    if options?
      extend(params, pick(options, @reservedKeys))
      params.reversed = options.isReversed if options.isReversed?
      params.tailed = options.hasTail if options.hasTail?
      params.invalidate = options.invalidate if options.invalidate?
      params.persistent = options.persistent if options.persistent?
      params.persistent = options.persist if options.persist?
      state = omit(options, @reservedKeys)
      params.state = state if size(state) > 0
    params

  constructor: (params) ->
    {@manager, @id, @range, @tailed, @reversed} = params
    {@valid, @invalidate, @persistent, @state} = params
    @tailed ?= true
    @reversed ?= false
    @valid ?= true
    @invalidate ?= 'surround'
    @persistent ?= true
    @state ?= {}
    Object.freeze(@state)

  getRange: ->
    if @hasTail()
      @range
    else
      new Range(@getHeadPosition(), @getHeadPosition())

  setRange: (range, options) ->
    params = @paramsFromOptions(options)
    params.range = Range.fromObject(range, true)
    @update(params)

  getHeadPosition: ->
    if @reversed
      @range.start
    else
      @range.end

  setHeadPosition: (position, options) ->
    position = Point.fromObject(position, true)
    params = @paramsFromOptions(options)

    if @reversed
      if position.isLessThan(@range.end)
        params.range = new Range(position, @range.end)
      else
        params.reversed = false
        params.range = new Range(@range.end, position)
    else
      if position.isLessThan(@range.start)
        params.reversed = true
        params.range = new Range(position, @range.start)
      else
        params.range = new Range(@range.start, position)

    @update(params)

  getTailPosition: ->
    if @hasTail()
      if @reversed
        @range.end
      else
        @range.start
    else
      @getHeadPosition()

  setTailPosition: (position, options) ->
    position = Point.fromObject(position, true)
    params = @paramsFromOptions(options)

    if @reversed
      if position.isLessThan(@range.start)
        params.reversed = false
        params.range = new Range(position, @range.start)
      else
        params.range = new Range(@range.start, position)
    else
      if position.isLessThan(@range.end)
        params.range = new Range(position, @range.end)
      else
        params.reversed = true
        params.range = new Range(@range.end, position)

    @update(params)

  clearTail: (options) ->
    params = @paramsFromOptions(options)
    params.tailed = false
    @update(params)

  plantTail: (options) ->
    params = @paramsFromOptions(options)
    unless @hasTail()
      params.tailed = true
      params.range = new Range(@getHeadPosition(), @getHeadPosition())
    @update(params)

  isReversed: ->
    @tailed and @reversed

  hasTail: ->
    @tailed

  isValid: ->
    @valid

  getInvalidationStrategy: ->
    @invalidate

  getState: ->
    @state

  copy: (options) ->
    @manager.createMarker(extend(@toParams(), @paramsFromOptions(options)))

  paramsFromOptions: (options) ->
    params = @constructor.paramsFromOptions(options)
    params.state = extend({}, @state, params.state) if params.state?
    params

  toParams: ->
    {@id, @range, @reversed, @tailed, @invalidate, @persistent, @state}

  update: (params) ->
    if patch = @buildPatch(params)
      @manager.recordMarkerPatch(patch)
      @applyPatch(patch)
      true
    else
      false

  handleBufferChange: (patch) ->
    {oldRange, newRange} = patch
    rowDelta = newRange.end.row - oldRange.end.row
    columnDelta = newRange.end.column - oldRange.end.column
    markerStart = @range.start
    markerEnd = @range.end

    return if markerEnd.isLessThan(oldRange.start)

    valid = @valid
    switch @getInvalidationStrategy()
      when 'surround'
        valid = markerStart.isLessThan(oldRange.start) or oldRange.end.isLessThanOrEqual(markerEnd)
      when 'overlap'
        valid = !oldRange.containsPoint(markerStart, true) and !oldRange.containsPoint(markerEnd, true)
      when 'inside'
        if @hasTail()
          valid = oldRange.end.isLessThan(markerStart) or markerEnd.isLessThan(oldRange.start)

    newMarkerRange = @range.copy()

    # Calculate new marker start position
    changeIsInsideMarker = @hasTail() and @range.containsRange(oldRange)
    if oldRange.start.isLessThanOrEqual(markerStart) and not changeIsInsideMarker
      if oldRange.end.isLessThanOrEqual(markerStart)
        # Change precedes marker start position; shift position according to row/column delta
        newMarkerRange.start.row += rowDelta
        newMarkerRange.start.column += columnDelta if oldRange.end.row is markerStart.row
      else
        # Change surrounds marker start position; move position to the end of the change
        newMarkerRange.start = newRange.end

    # Calculate new marker end position
    if oldRange.start.isLessThanOrEqual(markerEnd)
      if oldRange.end.isLessThanOrEqual(markerEnd)
        # Precedes marker end position; shift position according to row/column delta
        newMarkerRange.end.row += rowDelta
        newMarkerRange.end.column += columnDelta if oldRange.end.row is markerEnd.row
      else if oldRange.start.isLessThan(markerEnd)
        # Change surrounds marker end position; move position to the end of the change
        newMarkerRange.end = newRange.end

    if markerPatch = @buildPatch({valid, range: newMarkerRange})
      patch.addMarkerPatch(markerPatch)

  buildPatch: (newParams) ->
    oldParams = {}
    for name, value of newParams
      if isEqual(@[name], value)
        delete newParams[name]
      else
        oldParams[name] = @[name]

    if size(newParams)
      new MarkerPatch(@id, oldParams, newParams)

  applyPatch: (patch, bufferChanged=false) ->
    oldHeadPosition = @getHeadPosition()
    oldTailPosition = @getTailPosition()
    wasValid = @isValid()
    hadTail = @hasTail()
    oldState = @getState()

    updated = false
    {range, reversed, tailed, valid, state} = patch.newParams

    if range? and not range.isEqual(@range)
      @range = range.freeze()
      updated = true

    if reversed? and reversed isnt @reversed
      @reversed = reversed
      updated = true

    if tailed? and tailed isnt @tailed
      @tailed = tailed
      updated = true

    if valid? and valid isnt @valid
      @valid = valid
      updated = true

    if state? and not isEqual(state, @state)
      @state = Object.freeze(state)
      updated = true

    return false unless updated

    newHeadPosition = @getHeadPosition()
    newTailPosition = @getTailPosition()
    isValid = @isValid()
    hasTail = @hasTail()
    newState = @getState()

    @emit 'changed', {
      oldHeadPosition, newHeadPosition, oldTailPosition, newTailPosition
      wasValid, isValid, hadTail, hasTail, oldState, newState, bufferChanged
    }
    true