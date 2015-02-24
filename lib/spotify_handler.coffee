class SpotifyHandler
  constructor: (options) ->
    @spotify = options.spotify
    @config = options.config
    @storage = options.storage
    @storage.initSync()

    @connect_timeout = null
    @connected = false

    # "playing" in this context means actually playing music or being currently paused (but NOT stopped).
    # This is an important distinction regarding the functionality of @spotify.player.resume().
    @playing = false
    @paused = false

    @state = {
      shuffle: false
      loop: false
      chorum: @config.chorum || 1
      track:
        object: null
        index: 0
        name: null
        artists: null
        votes: []
      playlist:
        name: null
        object: null
    }

    @playlists = @storage.getItem('playlists') || {}

    @spotify.on
      ready: @spotify_connected.bind(@)
      logout: @spotify_disconnected.bind(@)
    @spotify.player.on
      endOfTrack: @skip.bind(@)

    # And off we got
    @connect()


  # Connects to Spotify.
  connect: ->
    @spotify.login @config.username, @config.password, false, false


  # Called after we have successfully connected to Spotify.
  # Clears the connect-timeout and grabs the default Playlist (or resumes playback if another playlist was set).
  spotify_connected: ->
    @connected = true
    clearTimeout @connect_timeout
    @connect_timeout = null

    # If we already have a set playlist (i.e. we were reconnecting), just keep playing.
    if @state.playlist.name?
      @play()
    # If we started fresh, get the one that we used last time
    else if last_playlist = @storage.getItem 'last_playlist'
      last_track = @storage.getItem 'track'
      @set_playlist last_playlist, last_track
    # If that didn't work, try one named "default"
    else if @playlists.default?
      @set_playlist 'default'
    return


  # Called after the handler has lost its connection to Spotify.
  # Attempts to re-connect every 2.5s.
  spotify_disconnected: ->
    @connected = false
    @connect_timeout = setTimeout (() => @connect), 2500
    return


  # Called after the current playlist has been updated.
  # Simply replaces the current playlist-instance with the new one and re-bind events.
  # Player-internal state (number of tracks in the playlist, current index, etc.) is updated on @get_next_track().
  update_playlist: (err, playlist, tracks, position) ->
    console.log("update_playlist: #{err}, #{playlist}, #{tracks}, #{position}")
    console.log("new playlist size: #{playlist.numTracks}")
    if @state.playlist.object?
      # Remove event handlers from the old playlist
      @state.playlist.object.off()
      console.log("old playlist size: #{@state.playlist.numTracks}")

    @state.playlist.object = playlist
    @state.playlist.object.on
      tracksAdded: @update_playlist.bind(this)
      tracksRemoved: @update_playlist.bind(this)
      tracksMoved: @update_playlist.bind(this)

    @state.playlist.object.on
      tracksAdded: (err, playlist, tracks, position) ->
        console.log "tracksAdded event"
        if position <= @state.track.index
          for track in tracks
            @state.track.index++
            console.log "Adding track #{track.link} #{track.name}"
          @store_track()
      tracksRemoved: (err, playlist, trackIndices) ->
        console.log "tracksRemoved event"
        for track_index in trackIndices
          if track_index <= @state.track.index
            @state.track.index--
        @store_track()
      tracksMoved: (err, playlist, trackIndices, position) ->
        console.log "tracksMoved event"
        for track_index in trackIndices
          if track_index <= @state.track.index
            @state.track.index--
          if position <= @state.track.index
            @state.track.index += position
        @store_track()
    return


  # Pauses playback at the current time. Can be resumed by calling @play().
  pause: ->
    @paused = true
    @spotify.player.pause()
    return


  # Stops playback. This does not just pause, but returns to the start of the current track.
  # This state can not be changed by simply calling @spotify.player.resume(), because reasons.
  # Call @play() to start playing again.
  stop: ->
    @playing = false
    @paused = false
    @spotify.player.stop()
    return


  # Plays the next track in the playlist
  skip: ->
    next_track = @get_next_track()
    if next_track
      @play next_track
    else
      @stop
    @store_track()
    return


  # Toggles shuffle on and off. MAGIC!
  toggle_shuffle: ->
    @shuffle = !@shuffle


  is_playing: ->
    return @playing


  is_paused: ->
    return @paused


  # Either starts the current track (or next one, if none is set) or immediately
  # plays the provided track or link.
  play: (track_or_link=null) ->
    @paused = false
    # If a track is given, immediately switch to it
    if track_or_link?
      switch typeof track_or_link
        # We got a link from Slack
        when 'string'
          # Links from Slack are encased like this: <spotify:track:1kl0Vn0FO4bbdrTbHw4IaQ>
          # So we remove everything that is neither char, number or a colon.
          new_track = @spotify.createFromLink @_sanitize_link(track_or_link)
          # If the track was somehow invalid, don't do anything
          return if !new_track?
        # We also use this to internally trigger playback of already-loaded tracks
        when 'object'
          new_track = track_or_link
        # Other input is simply disregarded
        else
          return
    # If we are already playing, simply resume
    else if @playing
      return @spotify.player.resume()
    # Last resort: We are currently neither playing not have stopped a track. So we grab the next one.
    else if !new_track
      new_track = @get_next_track()

    # We need to check whether the track has already completely loaded.
    if new_track? && new_track.isLoaded
      @_play_callback new_track
    else if new_track?
      @spotify.waitForLoaded [new_track], (track) =>
        @_play_callback new_track
    return


  # Handles the actual playback once the track object has been loaded from Spotify
  _play_callback: (track) ->
    @state.track.object = track
    @state.track.name = @state.track.object.name
    @state.track.artists = @state.track.object.artists.map((artist) ->
      artist.name
    ).join ", "
    @state.track.votes = []

    @spotify.player.play @state.track.object
    @playing = true
    return


  # Gets the next track from the playlist.
  get_next_track: ->
    # attempt to track the index (songs inserted / removed before index)
    if @shuffle
      @state.track.index = Math.floor(Math.random() * @state.playlist.object.numTracks)
    else
      if @loop
        @state.track.index = ++@state.track.index % @state.playlist.object.numTracks
      else
        @state.track.index = ++@state.track.index
    @state.playlist.object.getTrack(@state.track.index)

  store_track: ->
    track = {
      playlist_index: @state.track.index
      link: @state.track.object.link
    }
    console.log("Setting track to #{track}")
    @storage.setItem 'track', track

  # Changes the current playlist and starts playing.
  # Since the playlist might have loaded before we can attach our callback, the actual playlist-functionality
  # is extracted to _set_playlist_callback which we call either directly or delayed once it has loaded.
  set_playlist: (name, track) ->
    if @playlists[name]?
      playlist = @spotify.createFromLink @playlists[name]
      if playlist && playlist.isLoaded
        @_set_playlist_callback name, playlist, track
      else if playlist
        @spotify.waitForLoaded [playlist], (playlist) =>
          @_set_playlist_callback name, playlist, track
          return true
    return true


  # The actual handling of the new playlist once it has been loaded.
  _set_playlist_callback: (name, playlist, track) ->
    @state.playlist.name = name

    # Update our internal state
    @update_playlist null, playlist

    # default to the first track in the pla
    @state.track.index = 0
    # find any previous track
    if track?
      console.log "track: #{track}"
      potential = @state.playlist.object.getTrack(track.playlist_index)
      if potential.link == track.link
        @state.track.index = track.playlist_index
      else
        # let's search for the track
        for t, i in @state.playlist.object.getTracks
          if t.link == track.link
            @state.track.index = i
            break

    @play @state.playlist.object.getTrack(@state.track.index)
    # Also store the name as our last_playlist for the next time we start up
    @storage.setItem 'last_playlist', name
    return

  # Adds a playlist to the storage and updates our internal list
  add_playlist: (name, spotify_url) ->
    return false if !name? || !spotify_url? || !spotify_url.match(/spotify:user:.*:playlist:[0-9a-zA-Z]+/)
    spotify_url = @_sanitize_link spotify_url.match(/spotify:user:.*:playlist:[0-9a-zA-Z]+/g)[0]
    @playlists[name] = spotify_url
    @storage.setItem 'playlists', @playlists
    return true

  remove_playlist: (name) ->
    return false if !name? || !@playlists[name]?
    delete @playlists[name]
    @storage.setItem 'playlists', @playlists
    return true

  rename_playlist: (old_name, new_name) ->
    return false if !old_name? || !new_name? || !@playlists[old_name]?
    @playlists[new_name] = @playlists[old_name]
    delete @playlists[old_name]
    @storage.setItem 'playlists', @playlists
    return true

  # Removes Everything that shouldn't be in a link, especially Slack's <> encasing
  _sanitize_link: (link) ->
    link.replace /[^0-9a-zA-Z:#]/g, ''


# export things
module.exports = (options) ->
  return new SpotifyHandler(options)
