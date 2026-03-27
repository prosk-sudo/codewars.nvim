---@class cw.Api.Urls
local urls = {}

urls.base = "https://www.codewars.com"
urls.runner_base = "https://runner.codewars.com"

-- Public GET endpoints
urls.user = "/api/v1/users/%s"
urls.kata = "/api/v1/code-challenges/%s"
urls.completed = "/api/v1/users/%s/code-challenges/completed?page=%d"
urls.authored = "/api/v1/users/%s/code-challenges/authored"

-- Authenticated endpoints (require browser cookies)
-- Session: POST /kata/projects/{projectId}/{language}/session
-- Finalize: POST /kata/projects/{projectId}/solutions/{solutionId}/finalize
urls.authorize = "/api/v1/runner/authorize"
urls.run = "/run"
urls.notify = "/api/v1/code-challenges/projects/%s/solutions/%s/notify"
urls.finalize = "/api/v1/code-challenges/projects/%s/solutions/%s/finalize"

return urls
