InputView = null
SharePane = null

require './pusher/pusher'
require './pusher/pusher-js-client-auth'

{CompositeDisposable} = require 'atom'

randomstring = null
_ = null
chunkString = null

AtomPairConfig = null
CustomPaste = null
Invitation = null
HipChatInvitation = null
SlackInvitation = null
MessageQueue = null

module.exports = AtomPair =

  AtomPairView: null
  modalPanel: null
  subscriptions: null

  config:
    hipchat_token:
      type: 'string'
      description: 'HipChat admin token (optional)'
      default: ''
    hipchat_room_name:
      type: 'string'
      description: 'HipChat room name for sending invitations (optional)'
      default: ''
    pusher_app_key:
      type: 'string'
      description: 'Pusher App Key (sign up at http://pusher.com/signup and change for added security)'
      default: 'd41a439c438a100756f5'
    pusher_app_secret:
      type: 'string'
      description: 'Pusher App Secret'
      default: '4bf35003e819bb138249'
    slack_url:
      type: 'string'
      description: 'WebHook URL for Slack Incoming Webhook Integration'
      default: ''

  activate: (state) ->

    SharePane = require './modules/share_pane'

    InputView = require './views/input-view'

    randomstring = require 'randomstring'
    _ = require 'underscore'

    Invitation = require './modules/invitations/invitation'
    HipChatInvitation = require './modules/invitations/hipchat_invitation'
    SlackInvitation = require './modules/invitations/slack_invitation'

    AtomPairConfig = require './modules/atom_pair_config'
    MessageQueue = require './modules/message_queue'

    # Events subscribed to in atom's system can be easily cleaned up with a CompositeDisposable
    @subscriptions = new CompositeDisposable

    # Register command that toggles this view
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:start new pairing session': => new Invitation(@)
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:invite over hipchat': => new HipChatInvitation(@)
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:invite over slack': => new SlackInvitation(@)
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:join pairing session': => @joinSession()

    @colours = require('./helpers/colour-list')
    @friendColours = []
    _.extend(@, AtomPairConfig)

    @triggerPush = @engageTabListener = true

  disconnect: ->
    @pusher.disconnect()
    _.each @friendColours, (colour) => SharePane.each (pane) -> pane.clearMarkers(colour)
    SharePane.all = []
    @markerColour = null

  joinSession: ->

    if @markerColour
      atom.notifications.addError "It looks like you are already in a pairing session. Please open a new window (cmd+shift+N) to start/join a new one."
      return

    joinView = new InputView("Enter the session ID here:")
    joinView.miniEditor.focus()

    atom.commands.add joinView.element, 'core:confirm': =>
      @sessionId = joinView.miniEditor.getText()
      keys = @sessionId.split("-")
      [@app_key, @app_secret] = [keys[0], keys[1]]
      joinView.panel.hide()
      @pairingSetup()

  generateSessionId: ->
    @sessionId = "#{@app_key}-#{@app_secret}-#{randomstring.generate(11)}"

  ensureActiveTextEditor: (fn)->
    editor = atom.workspace.getActiveTextEditor()
    if !editor
      @triggerPush = false
      atom.workspace.open().then (editor)->
        @triggerPush = true
        fn(editor)
    else
      @triggerPush = true
      fn(editor)

  pairingSetup: ->
    @connectToPusher()
    @synchronizeColours()
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:disconnect': => @disconnect()

  connectToPusher: ->
    @pusher = new Pusher @app_key,
      authTransport: 'client'
      clientAuth:
        key: @app_key
        secret: @app_secret
        user_id: @markerColour || "blank"

    @queue = new MessageQueue(@pusher)

    @globalChannel = @pusher.subscribe("presence-session-#{@sessionId}")

  synchronizeColours: ->
    @globalChannel.bind 'pusher:subscription_succeeded', (members) =>
      @membersCount = members.count
      return @resubscribe() unless @markerColour
      colours = Object.keys(members.members)
      @friendColours = _.without(colours, @markerColour)
      _.each @friendColours, (colour) -> SharePane.each (pane) -> pane.addMarker 0, colour
      @startPairing()

  resubscribe: ->
    @globalChannel.unsubscribe()
    @markerColour = @colours[@membersCount - 1]
    @connectToPusher()
    @synchronizeColours()

  createSharePane: (editor, id) ->
    options = {
      editor: editor,
      pusher: @pusher,
      sessionId: @sessionId,
      markerColour: @markerColour,
      queue: @queue,
      id: id
    }

    new SharePane(options)

  setUpLeadership: ->
    @ensureActiveTextEditor =>
      _.each atom.workspace.getTextEditors(), (editor) => @createSharePane(editor)

  startPairing: ->

    if @leader then @setUpLeadership()

    @listenForNewTab()

    @globalChannel.bind 'client-created-share-pane',(data) =>
      return unless data.to is @markerColour or data.to is 'all'
      sharePane = SharePane.id(data.paneId)
      sharePane.shareFile()
      sharePane.sendGrammar()

    @globalChannel.bind 'client-create-share-pane', (data) =>
      return unless data.to is @markerColour or data.to is 'all'
      paneId = data.paneId
      @engageTabListener = false
      atom.workspace.open().then (editor)=>
        @createSharePane(editor, paneId)
        @queue.add(@globalChannel.name, 'client-created-share-pane', {to: data.from, paneId: paneId})
        @engageTabListener = true

    # GLOBAL
    @globalChannel.bind 'pusher:member_added', (member) =>
      atom.notifications.addSuccess "Your pair buddy has joined the session."
      @friendColours.push(member.id)
      return unless @leader
      SharePane.each (sharePane) =>
        @queue.add(@globalChannel.name, 'client-create-share-pane', {
          to: member.id,
          from: @markerColour,
          paneId: sharePane.id
        })
        sharePane.addMarker(0, member.id)

    # GLOBAL
    @globalChannel.bind 'pusher:member_removed', (member) =>
      SharePane.each (sharePane) -> sharePane.clearMarkers(member.id)
      atom.notifications.addWarning('Your pair buddy has left the session.')
      colours = Object.keys(@globalChannel.members.members)
      @leaderColour = _.sortBy(colours, (el) => @colours.indexOf(el))[0]
      if @leaderColour is @markerColour then @leader = true

    @listenForDestruction()

  listenForNewTab: ->
    atom.workspace.onDidOpen (e) =>
      return unless @engageTabListener
      editor = e.item
      sharePane = @createSharePane(editor)
      return unless @triggerPush
      @queue.add(@globalChannel.name, 'client-create-share-pane', {
        to: 'all',
        from: @markerColour,
        paneId: sharePane.id
      })

  listenForDestruction: ->
    SharePane.globalEmitter.on 'disconnected', =>
      if (_.all SharePane.all, (pane) => !pane.connected) then @disconnect()
