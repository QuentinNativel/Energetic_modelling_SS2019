using JuMP
#using Clp
using Gurobi
using DataFrames, CSV
using Plots; pyplot()
using StatsPlots


tech_df = CSV.read(joinpath("data","technologies.csv"))
storages_df = CSV.read(joinpath("data","storages.csv"))
timeseries_df = CSV.read(joinpath("data","timeseries.csv"))

STOR = storages_df[:Storages] |> Array
TECH = vcat(tech_df[:Technologies], STOR)
NONSTOR = setdiff(TECH, STOR)
RES = [row[:Technologies] for row in eachrow(tech_df) if row[:Renewable] == 1]
NONRES = [row[:Technologies] for row in eachrow(tech_df) if row[:Renewable] == 0]
DISP = [row[:Technologies] for row in eachrow(tech_df) if row[:Dispatchable] == 1]
NONDISP = [t for t in TECH if Symbol(t) in names(timeseries_df)]

dispatch = Model(with_optimizer(Gurobi.Optimizer))
@variables dispatch begin
        G[TECH, HOURS] >= 0
        D_Stor[STOR, HOURS] >= 0
        L_Stor[STOR, HOURS] >= 0
end

@objective(dispatch, Min,
        sum(mc[tech] * G[tech, hour] for tech in TECH, hour in HOURS)
        )
@constraint(dispatch,  Max_Generation[tech=TECH, hour=HOURS],
        G[tech, hour]
        <=
        (haskey(avail, tech) ? avail[tech][hour] * CAP_G[tech] : CAP_G[tech])
        );
