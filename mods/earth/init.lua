core.register_chatcommand("emerge_smart", {
    params = "radius [in_flight]",
    description = "Generate mapblock columns outwards in 2D rings and upwards through structures.",
    privs = {
        server = true,
    },
    func = function(name, params)
        return core.emerge_smart(name, params)
    end,
})
