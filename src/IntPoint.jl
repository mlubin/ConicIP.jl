isdefined(Base, :__precompile__) && __precompile__()

module IntPoint

export Id, Diag, intpoint, pivot, preprocess_intpoint, 
  IntPointSolver

import Base:+,*,-,\,^
using Base.LinAlg.BLAS:axpy!,scal!
using SymWoodburyMatrices
using BlockMatrices

include("kktsolvers.jl")

ViewTypes   = Union{SubArray}
VectorTypes = Union{Matrix, Vector, ViewTypes}
MatrixTypes = Union{Matrix, Array{Real,2},
                    SparseMatrixCSC{Real,Integer}}

# returns 0 for matrices with dimension 0.
normsafe(x) = isempty(x) ? 0 : norm(x)

# ──────────────────────────────────────────────────────────────
#  3x1 block vector
# ──────────────────────────────────────────────────────────────

type v4x1; y::Matrix; w::Matrix; v::Matrix; s::Matrix; end

+(a::v4x1, b::v4x1) = v4x1(a.y + b.y, a.w + b.w, a.v + b.v, a.s + b.s)
*(α::Real, a::v4x1) = v4x1(α*a.y, α*a.w, α*a.v, α*a.s);
-(a::v4x1)          = v4x1(-a.y, -a.w, -a.v, -a.s);
-(a::v4x1, b::v4x1) = v4x1(a.y - b.y, a.w - b.w, a.v - b.v, a.s - b.s)
Base.norm(a::v4x1)  = norm(a.y) + normsafe(a.w) + normsafe(a.v) + normsafe(a.s) 
Base.println(z::v4x1)  = println("y: ", z.y',
                         "\ng: ", z.w,
                         "\nv: ", z.v',
                         "\ns: ", z.s');

function axpy4!(α::Number, x::v4x1, y::v4x1)
    axpy!(α, x.y, y.y); axpy!(α, x.w, y.w)
    axpy!(α, x.v, y.v); axpy!(α, x.s, y.s)
end

# ──────────────────────────────────────────────────────────────
#  Linear operator representing a congurance transform of a
#  matrix in vectorized form
# ──────────────────────────────────────────────────────────────

type VecCongurance; R :: Matrix; end

*(W::VecCongurance, x::VectorTypes)    = vecm(W.R'*mat(x)*W.R)
\(W::VecCongurance, x::VectorTypes)    = inv(W)*x
Base.ctranspose(W::VecCongurance)      = VecCongurance(W.R');
Base.inv(W::VecCongurance)             = VecCongurance(inv(W.R))
Base.size(W::VecCongurance, i)         = round(Int, size(W.R,1)*(size(W.R,1)+1)/2)
Base.Ac_mul_B(W1::VecCongurance, W2::VecCongurance) = VecCongurance(W2.R*W1.R')

function Base.full(W::VecCongurance)
  n = size(W,1)
  I = eye(n)
  Z = zeros(n,n)
  for i = 1:n
    Z[:,i] = W*I[:,i][:]
  end
  return Z
end

function Base.sparse(W::VecCongurance)
  return sparse(full(W))
end

ord(x) = begin; n = length(x); round(Int, (sqrt(1+8*n) - 1)/2); end

function mat(x)

  # inverse of vecm
  # > mat([1,2,3,4,5,6)]
  #  1    2/√2  3√2
  #  2    4     5√2
  #  3√2  5√2   6

  n = ord(x)
  Z = zeros(n,n)
  for i = 1:n
    k = round(Int, length(x) - (n-i+2)*(n-i+1)/2)
    for j = 1:n
      if i <= j
        if i == j
          Z[i,j] = x[k+j-i+1]
        else
          Z[i,j] = x[k+j-i+1]/√2
        end
      else
        Z[i,j] = Z[j,i];
      end
    end
  end
  return Z

end

function vecm(Z)

  # inverse of mat
  # > vecm([1 2 3; 2 4 5; 3 5 6])
  # [1 2√2 3√2 4 5√2 6]

  n = size(Z,1)
  x = zeros(round(Int, n*(n+1)/2),1)
  c = 1
  for i = 1:n
    for j = 1:n
      if i <= j
        if i == j
          x[c] = Z[i,j];
        else
          x[c] = Z[i,j]*√2;
        end
        c = c + 1;
      end
    end
  end
  return x

end

# ──────────────────────────────────────────────────────────────
#  Misc Helper Types/Functions
# ──────────────────────────────────────────────────────────────

# Example:  block_ranges([1,1,3]) = [1:1,2:2,3:5]
cum_range(x) = [i:(j-1) for (i,j) in
        zip(cumsum([1;x])[1:end-1], cumsum([1;x])[2:end])]
QF(z::Vector)                    = 2*z[1]*z[1] - dot(z,z) # xᵀJx
Q(x::VectorTypes,y::VectorTypes) = 2*x[1]*y[1] - dot(x,y) # xᵀJy
fts(x₁, α₁, y₁, x₂, α₂, y₂)      = (x₁'*x₂) - α₂*(x₁'*y₂) -
          α₁*(y₁'*x₂) + α₁*α₂*(y₁'*y₂) # (x₁ - α₁*y₁)'(x₂ - α₂y₂)

function nestod_soc(z,s)

  # Nesterov-Todd Scaling Matrix for the second order cone
  # Matrix which satisfies the properties
  # W*z = inv(W)*s

  QF = r -> 2*r[1]*r[1] - dot(r,r)

  n = size(z,1)

  β = (QF(s)/QF(z))^(1/4)

  # Normalize z,s vectors
  z = z/sqrt(QF(z))
  s = s/sqrt(QF(s))

  γ = sqrt((1 + (z'*s)[1])/2)

  # Jz = J*z;
  Jz = -z; Jz[1] = -Jz[1]

  w = (1./(2.*γ))*(s + Jz)
  w[1] = w[1] + 1
  v = (sqrt(2*β)/sqrt(2*w[1]))*w

  J = Diag(β*ones(n))
  J.diag[1] = -β

  return SymWoodbury(J, reshape(v, length(v), 1), ones(1,1))

end

function nestod_sdc(z,s)

  # Nesterov-Todd Scaling Matrix for the Semidefinite Cone
  # Matrix which satisfies the properties
  # W*z = inv(W)*sb

  Ls  = chol(mat(s))'; 
  Lz  = chol(mat(z))'; 
  (U,Λ,V) = svd(Lz'*Ls)
  R = inv(Lz)'*U*spdiagm(sqrt(Λ))
  return VecCongurance(R)

end

function nestod_sdc_sym(z,s)

  # Symmetric Nesterov-Todd Scaling Matrix for the Semidefinite
  # Cone.

  Z  = mat(z); S  = mat(s); Sq = S^(0.5)
  (U,S,V) = svd(Sq*Z*Sq)
  E = U*spdiagm(1./sqrt(abs(S)))*U'
  R = Sq'*(E)*Sq
  (U,S,V) = svd(R)
  R = U*spdiagm(sqrt(abs(S)))*U'
  return VecCongurance(R)

  # (Us,Ss,Vs) = svd(S)
  # (Uz,Sz,Vz) = svd(Z)

  # Ss = Us*spdiagm(Ss.^(0.125))*Vs'
  # Zz = Uz*spdiagm(Sz.^(-0.25))*Vz'
  # return VecCongurance(Ss*Zz*Ss)
#  return VecCongurance(S^(0.125)*Z^(-0.25)*S^(0.125))

end

function maxstep_rp(x,d)

  # Assume x in R+.
  # Returns maximum α such that x + α*d in R+.

  # assert(all(x .> 0));

  #I = d .>= 0;
  #if all(!I); return 1; end # all directions unbounded

  minVal = Inf
  for i = 1:length(x)
    if d[i] > 0
      minVal = min(minVal, x[i]/d[i])
    end
  end
  return minVal

end

function maxstep_rp(x, e::Void)

  # Let α = inf { α | -x + αe >= 0 }
  # Then this returns
  # 0       if α < 0   (point is STRICTLY feasible)
  # 1 + α   otherwise

  if all(x .> 0)
    return 0;
  else
    return -1 + minimum(x);
  end

end

function maxstep_soc(x,d)

  # Assume x in Q.
  # Returns maximum α such that x - α*d in Q.

  # assert((norm(x[2:end]) <= x[1]))

  # J = -speye(size(x,1)); J[1,1] = 1; # Hyperbolic Identiy

  d = -d;
  γ = Q(x,x)
  xbar = x/sqrt(γ)
  β = Q(xbar,d)

  ρ1 = β /sqrt(γ)
  μ  = ((β + d[1])/(xbar[1] + 1))[1]
  ρ2 = (d[2:end] - μ*xbar[2:end])
  alpha = norm(ρ2)/sqrt(γ) - ρ1
  if alpha < 0
    return Inf
  else
    return 1/alpha
  end

end

function maxstep_soc(x, e::Void)

  # Maximum step to cone
  α = norm(x[2:end]) - x[1];
  return α < 0 ? 0 : -1 - α;

end

function maxstep_sdc(x,d)

  # Maximum step to Semidefinite cone
  X     = mat(x)^(-1/2);
  D     = mat(d)
  XDX   = X*D*X
  XDX   = 0.5*(XDX + XDX')
  (Λ,_) = eig(XDX)
  Λn    = Λ .< 0
  if all(Λn)
    return Inf
  else
    return 1/maximum(Λ[!Λn])
  end

end

function maxstep_sdc(x,d::Void)

  # Maximum step to Semidefinite cone
  X = mat(x)
  (Λ,_) = eig(X)
  minΛ  = minimum(Λ)
  return all(minΛ .> 0) ? 0 : -1 + minΛ

end

function drp!(x, y, o)

    for i = 1:length(x); o[i] = x[i]/y[i]; end

end

function xrp!(x, y, o)

    for i = 1:length(x); o[i] = x[i]*y[i]; end

end

function dsoc!(y,x, o)

  # Inverse of arrow matrix
  #     ┌                         ┐ ┌    ┐
  # α⁻¹ │  y1  -yb                │ │ x1 │
  #     │ -yb   (αI + yb*yb')/y1  │ │ xb │
  #     └                         ┘ └    ┘

  y1 = x[1]; yb = x[2:end]
  α = y1^2 - vecdot(yb,yb)

  x1 = y[1]; xb = y[2:end]
  o[1] = (y1*x1 - vecdot(yb,xb) )/α
  o[2:end] = (-yb*x1 + (α*xb + vecdot(yb,xb)*yb)/y1)/α

end

function xsoc!(x, y, o)

  o[1] = dot(x,y)
  for i = 2:length(x); o[i] = x[1]*y[i] + y[1]*x[i]; end

end

function dsdc!(x, y, o)

  n = round(Int, sqrt(size(x,1)))
  X = mat(x); Y = mat(y)
  o[:] = vecm(lyap(Y,-X))

end

function xsdc!(x, y, o)

  X = mat(x); Y = mat(y)
  o[:] = vecm(X*Y + Y*X)

end

# ──────────────────────────────────────────────────────────────
#  Interior Point
# ──────────────────────────────────────────────────────────────

type Solution

  y      :: Matrix  # primal
  w      :: Matrix  # dual (linear equality)
  v      :: Matrix  # dual (linear inequality)
  status :: Symbol  # :Optimal, :Infeasible
  Iter   :: Integer # number of iterations
  Mu     :: Real    # optimality conditions
  prFeas :: Real
  duFeas :: Real
  muFeas :: Real

end

"""
  intpoint(Q, c, A, b, cone_dims, G, d; 
  solve3x3gen = solve3x3gen_sparse,
  optTol = 1e-5,           
  DTB = 0.01,             
  verbose = true,         
  maxRefinementSteps = 3, 
  maxIters = 100,         
  cache_nestodd = false,  
  refinementThreshold = optTol/1e7)

Interior point solver for the system

```
minimize    ½yᵀQy - cᵀy
s.t         Ay >= b
            Gy  = d
```

Q,c,A,b,G,d are matrices (c,b,d are NOT vectors)

cone_dims is an array of tuples (Cone Type, Dimension)

```
e.g. [("R",2),("Q",4)] means
(y₁, y₂)          in  R+
(y₃, y₄, y₅, y₆)  in  Q
```

SDP Cones are NOT supported and purely experimental at this
point.

The parameter solve3x3gen allows the passing of a custom solver 
for the KKT System, as follows

```
julia> L = solve3x3gen(F,F⁻ᵀ,Q,A,G)

Then this 

julia> (a,b,c) = L(y,w,v)

solves the system
┌             ┐ ┌   ┐   ┌   ┐
│ Q   G'  -A' │ │ a │ = │ y │
│ G           │ │ b │   │ w │ 
│ A       FᵀF │ │ c │   │ v │
└             ┘ └   ┘   └   ┘  
```

We can also wrap a 2x2 solver using pivot3gen(solve2x2gen)
The 2x2 solves the system

```
julia> L = solve2x2gen(F,F⁻ᵀ,Q,A,G)

Then this 

julia> (a,b) = L(y,w) 

solves the system

┌                     ┐ ┌   ┐   ┌   ┐
│ Q + Aᵀinv(FᵀF)A  G' │ │ a │ = │ y │
│ G                   │ │ b │   │ w │
└                     ┘ └   ┘   └   ┘
```
"""
function intpoint(

  # ½xᵀQx - cᵀx
  Q, c::Matrix,

  # Ax ≧ b
  A, b::Matrix, cone_dims,

  # Gx = d
  G = spzeros(0,length(c)), d = zeros(0,1);

  # Solver Parameters

  # L = solve3x3gen(F,F⁻ᵀ,Q,A,G)
  # L(a,b,c) solves the system
  # ┌             ┐ ┌   ┐   ┌   ┐
  # │ Q   G'  -A' │ │ a │ = │ y │
  # │ G           │ │ b │   │ w │ 
  # │ A       FᵀF │ │ c │   │ v │
  # └             ┘ └   ┘   └   ┘  
  #
  # We can also wrap a 2x2 solver using pivot3gen(solve2x2gen)
  # The 2x2 solves the system
  # 
  # L = solve2x2gen(F,F⁻ᵀ,Q,A,G)
  # L(a,b) solves
  # ┌                ┐ ┌   ┐   ┌   ┐
  # │ Q + AᵀFᵀFA  G' │ │ a │ = │ y │
  # │ G              │ │ b │   │ w │
  # └                ┘ └   ┘   └   ┘
  kktsolver = kktsolver_qr,

  optTol = 1e-5,           # Optimal Tolerance
  DTB = 0.01,              # Distance to Boundary
  verbose = true,          # Verbose Output
  maxRefinementSteps = 3,  # Maximum number of IR Steps
  maxIters = 100,          # Maximum number of interior iterations
  cache_nestodd = false,   # Set to true if there are many small blocks
  refinementThreshold = optTol/1e7 # Accuracy of refinement steps

  )
   
  # Precomputed transposition matrices
  Aᵀ = A'; Gᵀ = G'

  n = length(c) # Number of variables
  m = size(A,1) # Number of inequality constraints
  p = size(G,1) # Number of equality constraints

  block_types  = [i[1] for i in cone_dims]
  block_sizes  = [i[2] for i in cone_dims]
  block_data   = zip(block_types, cum_range(block_sizes),
                     [i for i in 1:length(block_types)])

  # Sanity Checks
  ◂ = nothing
  #!(m == 0 && length(block_sizes) == 0) || m != sum(block_sizes) ? error("Inconsistency in inequalities") : ◂
  size(Q,1) != size(Q,2)? error("Q is not square") : ◂
  size(b,1) != m        ? error("Inconsistency in inequalities") : ◂
  size(c,1) != n        ? error("Inconsistency in inequalities/objective") : ◂
  size(d,1) != p        ? error("Inconsistency in equalities") : ◂
  size(G,2) != n        ? error("Inconsistency in equalities/objective") : ◂

  # Number to scale (z's) by
  # 1 for each R_+ dimension
  # 1 for each Q cone (regardless of dimension)
  conedim = 0
  for (btype, I, i) = block_data
    if btype == "R"; conedim += length(I);  end
    if btype == "Q"; conedim += 1;          end
    if btype == "S"; conedim += ord(I);     end
  end

  # e = conic group identity
  # Concatenate the vectors
  # [1, 1, … , 1] for R_+
  # [1, 0, … , 0] for Q
  # vecm(I)       for S
  e = zeros(m,1)
  for (btype, I, i) = block_data
    m_i = length(I)
    if btype == "R"; e[I] = ones(m_i,1);             end
    if btype == "Q"; e[I] = [1; zeros(m_i-1,1)];     end
    if btype == "S"; e[I] = vecm(eye(ord(I)));        end
  end

  # ──────────────────────────────────────────────────────────────
  #  Functions capturing cone_dims
  # ──────────────────────────────────────────────────────────────

  function maxstep(x, d)

    # Linesearch

    min_α = Inf;
    for (btype, I, i) = block_data
      xI = sub(x,I)
      dI = ( d == nothing ? nothing : sub(d,I) )
      if btype == "R"; α = maxstep_rp(xI,dI);  end
      if btype == "Q"; α = maxstep_soc(xI,dI); end
      if btype == "S"; α = maxstep_sdc(xI,dI); end
      min_α = min(α, min_α)
    end

    return min_α;

  end

  function is_feas(x)

    # Check if x is feasible

    for (btype, I, i) = block_data
      xI = sub(x,I); yI = sub(y,I);
      if btype == "R"; assert(x[I] > 0);                    end
      if btype == "Q"; assert(norm(x[I][2:end]) - x[I][1]); end
    end

  end

  function nt_scaling(x, y)

    # Compute Nesterov-Todd scaling matrix, F s.t.
    # λ = F*x = F\y

    B = Block(size(block_sizes,1));

    for (btype, I, i) = block_data
      xI = sub(x,I); yI = sub(y,I);
      if btype == "R"; B[i] = Diag(sqrt(yI./xI)); end
      if btype == "Q"; B[i] = nestod_soc(xI, yI); end
      if btype == "S"; B[i] = nestod_sdc(xI, yI); end
    end

    return B;

  end

  function ÷(x,y)

    # Group division x ○\ y

    o = zeros(length(x),1)
    for (btype, I, i) = block_data
      xI = sub(x,I); yI = sub(y,I); oI = sub(o,I)
      if btype == "R"; drp!(xI, yI, oI);  end
      if btype == "Q"; dsoc!(xI, yI, oI); end
      if btype == "S"; dsdc!(xI, yI, oI); end
    end
    return o;

  end

  function ∘(x,y)

    # Group product x ○ y

    o = zeros(length(x),1)
    for (btype, I, i) = block_data
      xI = sub(x,I); yI = sub(y,I); oI = sub(o,I)
      if btype == "R"; xrp!(xI, yI, oI);  end
      if btype == "Q"; xsoc!(xI, yI, oI); end
      if btype == "S"; xsdc!(xI, yI, oI); end
    end
    return o;

  end

  solve3x3gen = kktsolver(Q,A,G)

  function solve4x4gen(λ, F, F⁻ᵀ, solve3x3gen = solve3x3gen)

    #
    # solve4x4gen(λ, F)(r) solves the 4x4 KKT System
    # ┌                  ┐ ┌    ┐   ┌     ┐
    # │ Q   G'  -A'      │ │ Δy │ = │ r.y │
    # │ G                │ │ Δw │   │ r.w │ S = block(λ)*F
    # │ A             -I │ │ Δv │   │ r.v │ V = block(λ)*F⁻ᵀ
    # │          S     V │ │ Δs │   │ r.s │
    # └                  ┘ └    ┘   └     ┘
    # F = Nesterov-Todd scaling matrix
    #

    solve3x3 = solve3x3gen(F, F⁻ᵀ)

    function solve4x4(r)
      
      t1 = F'*(r.s ÷ λ) 
      (Δy, Δw, Δv)  = solve3x3(r.y, r.w, r.v + t1)
      axpy!(-1, F'*(F*Δv), t1) # > Δs = t1 - F*(F*Δv)
      return v4x1(Δy,Δw,Δv,t1)

    end

  end

  if verbose
      print("\n > INTERIOR POINT SOLVER v0.7 (July 2016)\n\n")
  end

  # ────────────────────────────────────────────────────────────
  #  Initial Point
  # ────────────────────────────────────────────────────────────

  I  = Block([Diag(ones(i)) for i = block_sizes])
  r0 = v4x1(c, d, b, zeros(m,1))
  z  = solve4x4gen(e,I,I)(r0)

  α_v = maxstep(z.v, nothing)
  α_s = maxstep(z.s, nothing)

  # Change to +
  z.v = z.v - α_v*e
  z.s = z.s - α_s*e

  if verbose
      ξ1()=@printf(" %-6s  %-10s  %-10s  %-10s  %-10s  %-10s\n",
                  "  Iter","Mu","prFeas","duFeas","muFeas","refine");ξ1()
  end

  # ────────────────────────────────────────────────────────────
  #  Iterate Loop
  # ────────────────────────────────────────────────────────────

  sol     = Solution(z.y, z.w, z.v, :Error, 0, 0, Inf, Inf, Inf)
  optBest = Inf
  
  for Iter = 1:maxIters

    F    = nt_scaling(z.v, z.s)   # Nesterov-Todd Scaling Matrix
    F⁻ᵀ  = inv(F)'
    λ    = F*z.v;                 # This is also F⁻ᵀ*z.s.

    # The cache is an optimization for the case where there are 
    # many tiny blocks. Since creating mutiple views is time 
    # consuming, we store F and F⁻ᵀ as big sparse matrices.
    if cache_nestodd == true; cache(F); cache(F⁻ᵀ); end

    solve = solve4x4gen(λ,F,F⁻ᵀ)   # Caches 4x4 solver
                                 # (used a few times, at least 2)

    #         ┌                   ┐ ┌     ┐
    # rleft = │ Q   G'   -A'      │ │ z.y │
    #         │ G                 │ │ z.w │  V = block(λ)*F⁻ᵀ
    #         │ A              -I │ │ z.v │    = block(λ)*λ
    #         │           S     V │ │ z.s │
    #         └                   ┘ └     ┘
    rleft = v4x1( Q*z.y + Gᵀ*z.w - Aᵀ*z.v ,
                  G*z.y                   ,
                  A*z.y - z.s             ,
                  λ ∘ λ                   )

    # True Residual of nonlinear KKT System
    r0 = v4x1(rleft.y - c, rleft.w - d, rleft.v - b, rleft.s);

    # ────────────────────────────────────────────────────────────
    #  Predictor
    # ────────────────────────────────────────────────────────────

    d_aff   = solve(r0)

    α_aff_v = min( maxstep( z.v, d_aff.v ) , 1 )
    α_aff_s = min( maxstep( z.s, d_aff.s ) , 1 )
    α_aff   = min( α_aff_v , α_aff_s )

    μbar = z.v'z.s
    # >> ρ  = (z.v - α_aff*d_aff.v)'*(z.s - α_aff*d_aff.s)/μbar
    ρ  = fts(z.v, α_aff, d_aff.v, z.s, α_aff,d_aff.s)/μbar
    σ  = max(0,min(1,ρ))^3
    μ  = μbar/conedim

    # ────────────────────────────────────────────────────────────
    #  Corrector
    # ────────────────────────────────────────────────────────────

    F⁻ᵀdfs = F⁻ᵀ*d_aff.s
    Fdfs   = F*d_aff.v

    # >> lc = -(F⁻ᵀdfs ∘ Fdfs) + (σ*μ)[1]*e;
    lc = (F⁻ᵀdfs ∘ Fdfs); axpy!(-(σ*μ)[1], e, lc);
    scal!(length(e), -1., lc, 1)

    r  =  v4x1(r0.y, r0.w, r0.v, rleft.s - lc)

    # ────────────────────────────────────────────────────────────
    #  Take newton step, with iterative refinement
    # ────────────────────────────────────────────────────────────

    Δz  = solve(r);
    rStep = 1;
    for rStep = 1:maxRefinementSteps
      r0  = v4x1( Q*Δz.y  + Gᵀ*Δz.w  - Aᵀ*Δz.v ,
                  G*Δz.y                       ,
                  A*Δz.y - Δz.s                ,
                  λ∘(F*Δz.v) + λ∘(F⁻ᵀ*Δz.s) )
      rIr = r - r0
      rnorm = norm(rIr)/(n + 2*m)
      if rnorm > 0.1
        verbose ? warn("4x4 solve failed, residual norm $(rnorm)") : ◂
      end
      if rnorm < refinementThreshold; break; end
      Δzr = solve(rIr)
      Δz  = Δz + Δzr
    end

    α_v = min( maxstep(z.v, Δz.v/(1-DTB)), 1 )
    α_s = min( maxstep(z.s, Δz.s/(1-DTB)), 1 )
    α   = min( α_v, α_s )

    # >> z = z - α*Δz;
    axpy4!(-α, Δz, z)

    # ────────────────────────────────────────────────────────────
    #  Print iterate status
    # ────────────────────────────────────────────────────────────

    rDu = norm(r0.y)/(1+norm(c))
    rPr = normsafe(r0.v)/(1 + normsafe(b))
    rCp = normsafe(r0.s)/(1+abs(c'z.y)[1]); # [1] acts as a cast

    if max(rDu, rPr, rCp) < optBest
      sol.y[:] = z.y; sol.w[:] = z.w; sol.v[:] = z.v
      sol.Iter = Iter; sol.Mu = μ[1]; 
      sol.duFeas = rDu; sol.prFeas = rPr; sol.muFeas = rCp
      optBest = max(rDu, rPr, rCp)
    end

    if verbose
        ξ2()=@printf(" %6i  %-10.4e  %-10.4e  %-10.4e  %-10.4e  %i\n",
                    Iter, μ[1], rDu, rPr, rCp, rStep);ξ2()
    end    

    if max(rDu, rPr, rCp) < optTol
        if verbose
            print("\n > EXIT -- Below Tolerance!\n\n")
        end
        sol.status = :Optimal
        return sol
    end

    # ────────────────────────────────────────────────────────────
    # If iterates blow up, diagonose divergence
    # ────────────────────────────────────────────────────────────
    if max(μ[1], rDu, rPr, rCp) > 1/optTol || !all(isfinite([μ[1], rDu, rPr, rCp]))

        # Primal Infeasible
        r_infeas = norm(Gᵀ*z.w + Aᵀ*z.v)[1]/(b'*z.v + d'*z.w)[1]

        if r_infeas/(1+norm(c)) < optTol

          if verbose
            print("\n > EXIT -- Infeasible!\n\n")
          end
          sol.status = :Infeasible
          return sol

        end 

        # Dual Infeasible
        r_dual_infeas1 = isempty(A) ? -Inf : (A*z.y - z.s)[1]/vecdot(c,z.y)
        r_dual_infeas2 = isempty(G) ? -Inf : norm(G*z.y - d)

        if max(r_dual_infeas1, r_dual_infeas2) < optTol

          if verbose
            print("\n > EXIT -- Dual Infeasible!\n\n")
          end
          sol.status = :DualInfeasible
          return sol

        end

        # Cause of Divergence Unknown
        if verbose
            print("\n > EXIT -- Error!\n\n")
        end
        sol.status = :Error
        return sol

    end

  end

  sol.status = :Abandoned
  return sol

end

include("low_level_wrapper.jl")
include("preprocessor.jl")

end
