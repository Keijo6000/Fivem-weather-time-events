fx_version 'cerulean'
game 'gta5'

author '6K'
name 'maailma'
description 'Sään, ajan ja erikoiseventtien hallinta'
version '1.0.0'

lua54 'yes'

ui_page 'html/index.html'

client_scripts {
    'client.lua'
}

server_scripts {
    'server.lua'
}

shared_scripts {
    'config.lua'
}

files {
    'html/index.html',
    'flood.xml',
    'events.xml'
}

data_file 'TIMECYCLEMOD_FILE' 'events.xml'

dependencies {
    'ox_lib'
}
