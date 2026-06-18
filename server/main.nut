local Application = import("src/application.nut")

local app = Application.RepositoryApplication(vargv)
local status = app.run(vargv)
return status
