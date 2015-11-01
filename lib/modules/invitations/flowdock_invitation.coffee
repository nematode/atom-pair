Invitation = require './invitation'
Flowdock = require 'flowdock'
_ = require 'underscore'

module.exports =
class FlowdockInvitation extends Invitation

  needsInput: true
  askRecipientName: "Please enter the Flowdock name of your pair partner (or flow):"

  checkConfig: ->
    if @session.missingFlowdockKey()
      atom.notifications.addError("Please set your Flowdock key.")
      false
    else
      true

  getFlowdock: ->
    try
      @session = new Flowdock.Session(@flowdock_key)
      @session.on 'error', () -> _.noop  #prevent errors from affecting Atom
    catch error
      atom.notifications.addError("Could not connect to Flowdock. Please check your API key.")
      return

  send: (done) ->
    @getFlowdock()

    inviteText = "Hello there #{messageRcpt}. You have been invited to a pairing session. If you haven't installed the AtomPair plugin, type \`apm install atom-pair\` into your terminal. Go onto Atom, hit 'Join a pairing session', and enter this string: `#{@sessionId}`"

    recipientType = @getRecipientType() # THIS DOES NOT WORK; ASYNC PROGRAMMING FAIL. Need to wait for @getRecipient to return. How?

    if recipientType is 'user'
      # send a message to the user
      @session.privateMessage recipient.id, inviteText, (err, message, res) =>
        console.log 'Sending invite...'
        atom.notifications.addInfo("#{messageRcpt} has been sent an invitation. Hold tight!")
        @markerColour = @colours[0]
        return

    if recipientType is 'flow'
      # send a message to the flow
      @session.message recipient.id, inviteText, (err, message, res) =>
        atom.notifications.addInfo("#{messageRcpt} has been sent an invitation. Hold tight!")
        @markerColour = @colours[0]
        return

  getRecipientType: ->
    isNickLookup = @recipient.charAt(0) is '@'
    rcptAlias = if isNickLookup then @recipient.slice(1).toUpperCase() else @recipient.toUpperCase()

    # Can't be sure if we're inviting a user or a flow. Try users then flows.
    @session.get '/users', {}, (err, message, res) ->
      if err then atom.notifications.addError("Could not fetch Flowdock users.")

      users = res.body
      userRcpt = _.find users, (user) ->
        if isNickLookup
          return rcptAlias is user.nick.toUpperCase()
        else
          return rcptAlias is user.nick.toUpperCase() or rcptAlias is user.name.toUpperCase()

      if userRcpt
        console.log userRcpt
        return {type: 'user', id: userRcpt.id}

    # check flows if we're still emptyhanded and not searching nicks
    if !isNickLookup
      @session.flows (err, flows) ->
        flowRcpt = _.find flows, (flow) ->
          rcptAlias is flow.name.toUpperCase() or rcptAlias is flow.parameterized_name.toUpperCase()

        if flowRcpt
          console.log flowRcpt
          return {type: 'flow', id: flowRcpt.id}

        atom.notifications.addError("Could not find a flow or user matching #{messageRcpt}.")
