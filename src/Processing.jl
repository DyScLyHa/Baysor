module Processing

using LazyModules

using DataFrames

@lazy import KernelDensity as KDE = "5ab0869b-81aa-558d-bb23-cbf5423bbe9b"

@lazy import Colors = "5ae59095-9a9b-59fe-a467-6f913c188581"
@lazy import ImageMorphology = "787d08f9-d448-5407-9aad-5290dd7ab264"

using Distributions
using LinearAlgebra
using ProgressMeter
using Statistics

import Distributions.pdf
import Distributions.logpdf
import Statistics.rand

include("utils/shared_utils.jl")
include("utils/utils.jl")
include("utils/convex_hull.jl")

include("distributions/MvNormal.jl")
include("distributions/CategoricalSmoothed.jl")

include("models/InitialParams.jl")
include("models/Component.jl")
include("models/BmmData.jl")

include("data_processing/triangulation.jl")
include("data_processing/umap_wrappers.jl")
include("data_processing/neighborhood_composition.jl")
include("data_processing/noise_estimation.jl")
include("data_processing/initialization.jl")
include("data_processing/boundary_estimation.jl")

include("bmm_algorithm/molecule_clustering.jl")
include("bmm_algorithm/compartment_segmentation.jl")
include("bmm_algorithm/tracing.jl")
include("bmm_algorithm/distribution_samplers.jl")
include("bmm_algorithm/history_analysis.jl")
include("bmm_algorithm/bmm_algorithm.jl")

end