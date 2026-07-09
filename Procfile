db: docker start hyper-pg > /dev/null && docker logs --follow hyper-pg
hyper: until docker exec hyper-pg pg_isready -U postgres > /dev/null 2>&1; do sleep 1; done && mix ecto.migrate -r Hyper.Img.Db.Repo && exec iex -S mix
