function initiate_SAGA( prob::Prob, options::MyOptions ; minibatch_type="nice", probability_type = "", unbiased = true)
  # function for setting the parameters and initiating the SAGA method (and all it's variants)
  options.stepsize_multiplier =1;
  epocsperiter = options.batchsize/prob.numdata;
  gradsperiter = options.batchsize;
  if(unbiased)
    name = "SAGA"
  else
    name = "SAG"
  end
  if(options.batchsize>1)
    name = string(name,"-",options.batchsize);
  end
  minibatches =[];
  Jacsp = spzeros(1);#spzeros(prob.numfeatures,prob.numdata);
  SAGgrad = zeros(prob.numfeatures);
  gi = zeros(prob.numfeatures);
  aux = zeros(prob.numfeatures);
  descent_method = descent_SAGA;
  probs = []; Z =0.0; stepsize =0.0
  mu = get_mu_str_conv(prob);

  if(minibatch_type =="partition")
    # L = mean(sum(prob.X.^2,1));
    if(probability_type == "ada")
      if(options.initial_point =="randn")
        xstart = randn(prob.numfeatures);
      elseif(options.initial_point =="zeros")
        println("adaSAGA doesn't work well with zeros initial point! Existing")
        return [];
      else
        xstart = rand(prob.numfeatures);
      end
      Jac= zeros(prob.numdata);
      # Jac= zeros(prob.numfeatures, prob.numdata);
      name = string(name,"-",probability_type);
      yXx = prob.y.*(prob.X'*xstart); # initial random guess
      probs =logistic_phi(yXx) ;
      probs[:] = probs.*(1-probs);
      probs[:] = max.(probs, 0.25/8.0); ## IMPORTANT: this establishes a minimum value for phi''
      probs[:] = probs.*vec(sum(prob.X.^2,1))+prob.lambda;
      Lmax= maximum(probs);
      L = mean(probs);
      probs[:] = probs.*4 + prob.numdata*mu;
      Z = sum(probs);
      probs[:] = probs/Z;
      stepsize = prob.numdata/Z;
      descent_method =  descent_SAGA_adapt2;#descent_SAGA_adapt;
    else
      Jac, minibatches, probs, name, L, Lmax, stepsize = boot_SAGA_partition(prob,options,probability_type,name,mu);
      descent_method = descent_SAGApartition;
    end
    # elseif(minibatch_type =="Li_order_partition")
  elseif(minibatch_type == "Li_order_partition")
    Jac, minibatches, probs, name, L, Lmax = boot_SAGA_Li_order_partition(prob,options,probability_type,name,mu);
    descent_method = descent_SAGApartition;
  else
    name = string(name,"-",minibatch_type);
    L = eigmax(full(prob.X*prob.X'))/prob.numdata+prob.lambda;
    Lmax = maximum(sum(prob.X.^2,1))+prob.lambda;
    Jac= zeros(prob.numfeatures, prob.numdata);
  end
  return SAGAmethod(epocsperiter, gradsperiter,name, descent_method, boot_SAGA, minibatches, minibatch_type, unbiased,
  Jac, Jacsp, SAGgrad, gi, aux, stepsize, probs, probability_type, Z, L, Lmax, mu);
end
#
function boot_SAGA(prob::Prob,method,options::MyOptions)

  tau = options.batchsize;
  n = prob.numdata;
  if(method.minibatch_type =="partition")  # 1/(4 L + n/tau mu)
    if(method.probability_type == "uni")
      Lexpected = method.Lmax;
    else
      Lexpected = method.L;
    end
  else # nice sampling     # interpolate Lmax and L
    Lexpected =   exp((1-tau)/( (n+0.1) -tau))*method.Lmax + ((tau-1)/(n-1))*method.L;
  end
  if (contains(prob.name,"lgstc"))
    Lexpected = Lexpected/4;    #  correcting for logistic since phi'' <= 1/4
  end
  method.stepsize = options.stepsize_multiplier/(4*Lexpected+ (n/tau)*method.mu);
  if(options.skip_error_calculation ==0.0)
    options.skip_error_calculation =ceil(options.max_epocs*prob.numdata/(options.batchsize*30) ); # show 5 times per pass over the data
    # 20 points over options.max_epocs when there are options.max_epocs *prob.numdata/(options.batchsize)) iterates in total
  end
  println("Skipping ", options.skip_error_calculation, " iterations per epoch")
  return method;
end


function boot_SAGA_partition(prob::Prob,options::MyOptions, probability_type::AbstractString, name::AbstractString, mu::Float64)
  ## Setting up a partition mini-batch
  numpartitions = convert(Int64, ceil(prob.numdata/options.batchsize)) ;
  # Jac = zeros(prob.numfeatures, numpartitions);
  Jac = zeros(prob.numdata);
  #shuffle the data and then cute in contigious minibatches
  datashuff = shuffle(1:1:prob.numdata);
  # Pad wtih randomly selected indices
  resize!(datashuff, numpartitions*options.batchsize);
  samplesize = numpartitions*options.batchsize - prob.numdata;
  s = sample(1:prob.numdata,samplesize,replace=false);
  datashuff[prob.numdata+1:end] = s;
  # look up repmat or reshape matrix
  minibatches = reshape(datashuff, numpartitions, options.batchsize);
  ## Setting the probabilities
  probs = zeros(1,numpartitions);
  name = string(name,"-",probability_type);
  for i =1:numpartitions      # Calculating the Li's assumming it's a phi'' < 1. Remember for logistic fuction phi'' <1/4
    probs[i] = get_LC(prob, minibatches[i,:]);
    # probs[i] = eigmax(Symmetric(prob.X[:,minibatches[i,:]]'*prob.X[:,minibatches[i,:]]))/options.batchsize +prob.lambda;
  end
  Lmax= maximum(probs);
  L = mean(probs);
  if(probability_type == "Li")
    probs[:] = probs./sum(probs);
    stepsize = 1/(4*L+numpartitions*mu);
  elseif(probability_type == "uni")
    probs[:] .= 1/numpartitions;
    stepsize = 1/(4*Lmax+numpartitions*mu);
  else
    probs[:] = probs.*4.+numpartitions*mu;
    stepsize = 1/(mean(probs));
    probs[:] = probs./sum(probs);
  end
  # probs[ = vec(probs);
  return Jac, minibatches, vec(probs), name, L, Lmax, stepsize
end



function boot_SAGA_Li_order_partition(prob::Prob,options::MyOptions, probability_type::AbstractString, name::AbstractString, mu::Float64)
  ## This is a partition mini-batching that groups mini-batches together based on the sum_i L_i.
  ## Setting up a partition mini-batch
  numpartitions = convert(Int64, ceil(prob.numdata/options.batchsize)) ;
  # Jac = zeros(prob.numfeatures, numpartitions);
  Jac = zeros(prob.numdata);
  # allocate space for minibatch sets
  minibatches = zeros(Int64, numpartitions, options.batchsize);
  ## Setting the probabilities
  probs = zeros(1,numpartitions);
  Lis = zeros(prob.numdata);
  for i =1:prob.numdata      # Calculating the Li's assumming it's a phi'' < 1
    Lis[i] = get_LC(prob, [i]);
  end
  sortindices = sortperm(Lis);
  addonend = numpartitions*options.batchsize - prob.numdata;
  sortindices = [sortindices ; sortindices[1:addonend]]; # extending to match dimension
  layernum = 1;
  for i =1:(numpartitions*options.batchsize)
    parti = i%(numpartitions);
    if(parti ==0)    parti = numpartitions; end
    if(iseven(layernum)) # switch direction to give a more balanced partitions
      minibatches[parti, layernum] = sortindices[i];
      # println("i :", i, "  part :", parti, "  layernum:", layernum, "  Lis[sortindices[i]]:", Lis[sortindices[i]])
    else
      minibatches[(numpartitions +1 -parti), layernum] = sortindices[i];
      # println("i :", i, "  part :", (numpartitions +1 -parti), "  layernum:", layernum, "  Lis[sortindices[i]]:", Lis[sortindices[i]])
    end
    if(parti ==numpartitions)    layernum = layernum +1;   end
  end
  for i =1:numpartitions      # Calculating the Li's assumming it's a phi'' < 1. Remember for logistic fuction phi'' <1/4
    probs[i] = get_LC(prob, minibatches[i,:]);
    # probs[i] = eigmax(Symmetric(prob.X[:,minibatches[i,:]]'*prob.X[:,minibatches[i,:]]))/options.batchsize +prob.lambda;
  end
  Lmax= maximum(probs);
  L = mean(probs);
  if(probability_type == "Li")
    probs[:] = probs./sum(probs);
  elseif(probability_type == "uni")
    probs[:] .= 1/numpartitions;
  else
    probs[:] = probs.*4.+numpartitions*mu;
    probs[:] = probs./sum(probs);
  end

  # Lcuppers = zeros(numpartitions);
  # for i = 1: numpartitions
  #   Lcuppers[i] = mean(Lis[convert(Array{Int64},minibatches[i,:])])
  # end
  #
  name = string(name,"-Li_order_partition-", probability_type);
  # probs[ = vec(probs);
  return Jac, minibatches, vec(probs), name, L, Lmax
end
